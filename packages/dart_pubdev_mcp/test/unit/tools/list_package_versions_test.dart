/// Unit tests for [ListPackageVersionsHandler].
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:dart_pubdev_mcp/src/cache/cache_registry.dart';
import 'package:dart_pubdev_mcp/src/data/domain_error.dart';
import 'package:dart_pubdev_mcp/src/tools/list_package_versions.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';

// ─── Helpers ──────────────────────────────────────────────────────────────────

/// Creates a [CallToolRequest] for `list_package_versions` with [name].
CallToolRequest _request(String name) =>
    CallToolRequest(name: 'list_package_versions', arguments: {'package': name});

/// Decodes the first content item of [result] as a JSON map.
Map<String, Object?> _payload(CallToolResult result) =>
    jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;

/// Extracts the inner `error` object from a failed result's nested error schema.
Map<String, Object?> _errorInner(CallToolResult result) {
  final inner = _payload(result)['error'];
  if (inner is! Map<String, Object?>) throw StateError('No nested error object');
  return inner;
}

/// Extracts the named bucket as a list of version maps.
List<Map<String, Object?>> _bucket(CallToolResult result, String name) =>
    ((_payload(result)[name] as List<Object?>?) ?? const []).cast<Map<String, Object?>>();

/// Extracts the ordered version strings of the named bucket.
List<String> _versions(CallToolResult result, String bucket) =>
    _bucket(result, bucket).map((e) => (e['version'] as String?) ?? '').toList();

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late TestStack stack;
  late MockHttpClient mockHttp;
  late CacheRegistry registry;

  ListPackageVersionsHandler buildHandler() => ListPackageVersionsHandler(
    versionList: registry.versionList,
    log: (_, _) {},
  );

  setUp(() {
    stack = TestStack();
    mockHttp = stack.http;
    registry = stack.caches;
  });

  tearDown(() => stack.close());

  // ─── Input validation ─────────────────────────────────────────────────────────

  group('input validation', () {
    test('empty name sets isError to true', () async {
      final result = await buildHandler().call(_request(''));

      expect(result.isError, isTrue);
    });

    test('empty name returns an INVALID_ARGUMENT domain error', () async {
      final result = await buildHandler().call(_request(''));

      expect(_errorInner(result)['code'], equals(DomainErrors.invalidArgument));
    });
  });

  // ─── Package not found ──────────────────────────────────────────────────────────

  group('package not found', () {
    test('unknown package sets isError to true', () async {
      stubUrl(mock: mockHttp, urlFragment: '/api/packages/nope', response: notFound());

      final result = await buildHandler().call(_request('nope'));

      expect(result.isError, isTrue);
    });

    test('unknown package returns PACKAGE_NOT_FOUND', () async {
      stubUrl(mock: mockHttp, urlFragment: '/api/packages/nope', response: notFound());

      final result = await buildHandler().call(_request('nope'));

      expect(_errorInner(result)['code'], equals(DomainErrors.packageNotFound));
    });
  });

  // ─── Bucketing ──────────────────────────────────────────────────────────────────

  group('bucketing', () {
    setUp(() {
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http',
        response: ok(readFixture('package_versions.json')),
      );
    });

    test('package field echoes the requested name', () async {
      final result = await buildHandler().call(_request('http'));

      expect(_payload(result)['package'], equals('http'));
    });

    test('stable bucket holds only non-retracted stable versions', () async {
      final result = await buildHandler().call(_request('http'));

      expect(_versions(result, 'stable'), equals(['1.2.0', '1.1.0', '1.0.0']));
    });

    test('prerelease bucket holds only non-retracted pre-release versions', () async {
      final result = await buildHandler().call(_request('http'));

      expect(_versions(result, 'prerelease'), equals(['1.3.0-beta.1', '1.1.0-beta.1']));
    });

    test('retracted bucket holds the retracted version', () async {
      final result = await buildHandler().call(_request('http'));

      expect(_versions(result, 'retracted'), equals(['1.1.3']));
    });

    test('retracted version is absent from the stable bucket', () async {
      final result = await buildHandler().call(_request('http'));

      expect(_versions(result, 'stable'), isNot(contains('1.1.3')));
    });

    test('each entry carries a version and an ISO 8601 publishedAt', () async {
      final result = await buildHandler().call(_request('http'));
      final entry = _bucket(result, 'stable').first;
      final published = entry['publishedAt'] as String?;

      expect(entry['version'], equals('1.2.0'));
      expect(published, isNotNull);
      expect(DateTime.tryParse(published ?? ''), isNotNull);
    });
  });

  // ─── Ordering ─────────────────────────────────────────────────────────────────

  group('ordering', () {
    test('buckets are sorted newest-first even when the source is oldest-first', () async {
      // The fixture lists versions oldest-first; the handler must reorder.
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http',
        response: ok(readFixture('package_versions.json')),
      );

      final result = await buildHandler().call(_request('http'));
      final stable = _bucket(
        result,
        'stable',
      ).map((e) => DateTime.parse((e['publishedAt'] as String?) ?? '')).toList();

      for (var i = 0; i + 1 < stable.length; i++) {
        expect(
          stable[i].isAfter(stable[i + 1]),
          isTrue,
          reason: 'stable[$i] should be newer than stable[${i + 1}]',
        );
      }
    });
  });

  // ─── Retraction precedence ──────────────────────────────────────────────────────

  group('retraction precedence', () {
    test('a retracted pre-release lands in retracted, not prerelease', () async {
      const body = '''
      {
        "name": "demo",
        "versions": [
          {"version": "2.0.0-dev.1", "published": "2024-01-01T00:00:00.000Z", "retracted": true}
        ]
      }''';
      stubUrl(mock: mockHttp, urlFragment: '/api/packages/demo', response: ok(body));

      final result = await buildHandler().call(_request('demo'));

      expect(_versions(result, 'retracted'), equals(['2.0.0-dev.1']));
      expect(_versions(result, 'prerelease'), isEmpty);
    });
  });

  // ─── Caching ──────────────────────────────────────────────────────────────────

  group('caching', () {
    test('does not issue a second HTTP request for a cached package', () async {
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http',
        response: ok(readFixture('package_versions.json')),
      );
      final handler = buildHandler();

      await handler.call(_request('http'));
      await handler.call(_request('http'));

      verify(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('/api/packages/http'))),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });
  });
}
