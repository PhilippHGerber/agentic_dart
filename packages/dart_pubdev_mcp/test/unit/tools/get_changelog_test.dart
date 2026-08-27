/// Unit tests for [GetChangelogHandler].
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:dart_pubdev_mcp/src/cache/cache_registry.dart';
import 'package:dart_pubdev_mcp/src/data/domain_error.dart';
import 'package:dart_pubdev_mcp/src/data/pub_client.dart';
import 'package:dart_pubdev_mcp/src/tools/get_changelog.dart';
import 'package:dart_pubdev_mcp/src/tools/version_resolver.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';
import '../../support/pub_stubs.dart';

// ─── Helpers ──────────────────────────────────────────────────────────────────

/// Stubs a successful changelog fetch for package [name].
///
/// Also stubs the version-resolution endpoint so [PubDevClient.resolveLatestStable]
/// succeeds.
void _stubSuccess(MockHttpClient mock, {String name = 'http', String? html}) {
  stubPackageInfo(mock, packageName: name);
  stubUrl(
    mock: mock,
    urlFragment: '/packages/$name/changelog',
    response: ok(html ?? _defaultChangelogHtml),
  );
}

/// HTML with three versions: 2.0.0 (breaking), 1.5.0, 1.0.0.
const _defaultChangelogHtml = '''
<h2>2.0.0</h2>
<p>Breaking change: removed the old API.</p>
<h2>1.5.0</h2>
<p>Added new feature.</p>
<h2>1.0.0</h2>
<p>Initial release.</p>
''';

/// HTML using bracketed version format.
const _bracketedChangelogHtml = '''
<h2>[2.0.0]</h2>
<p>Breaking change: removed the old API.</p>
<h2>[1.0.0]</h2>
<p>Initial release.</p>
''';

/// HTML with no version headings.
const _noHeadingsHtml = '<p>This package has no formal changelog yet.</p>';

/// Creates a [CallToolRequest] for `get_changelog` with the given [args].
CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'get_changelog', arguments: args);

/// Decodes the first content item of [result] as a JSON success object and
/// returns the `entries` list.
List<Map<String, Object?>> _entries(CallToolResult result) {
  final json = jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;
  return ((json['entries'] as List<Object?>?) ?? const []).cast<Map<String, Object?>>();
}

/// Decodes the first content item of [result] and returns its `resolvedVersion`.
String? _resolvedVersion(CallToolResult result) {
  final json = jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;
  return json['resolvedVersion'] as String?;
}

/// Decodes the first content item of [result] and returns its `package`.
String? _package(CallToolResult result) {
  final json = jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;
  return json['package'] as String?;
}

/// Decodes the first content item of [result] as a JSON error payload.
Map<String, Object?> _errorPayload(CallToolResult result) {
  final outer = jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;
  final inner = outer['error'];
  if (inner is! Map<String, Object?>) throw StateError('No nested error object');
  return inner;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late TestStack stack;
  late MockHttpClient mockHttp;
  late VersionResolver versionResolver;
  late DateTime fakeNow;
  late CacheRegistry registry;
  final loggedMessages = <(LoggingLevel, Object)>[];

  GetChangelogHandler buildHandler() => GetChangelogHandler(
    versionResolver: versionResolver,
    changelog: registry.changelog,
    log: (level, data) => loggedMessages.add((level, data)),
  );

  setUp(() {
    fakeNow = DateTime(2026, 5, 12);
    stack = TestStack(clock: () => fakeNow);
    mockHttp = stack.http;
    versionResolver = VersionResolver(
      client: stack.client,
      log: (level, data) => loggedMessages.add((level, data)),
    );
    registry = stack.caches;
    loggedMessages.clear();
  });

  tearDown(() => stack.close());

  // ─── Successful parse ─────────────────────────────────────────────────────────

  group('successful parse', () {
    test('returns a JSON list without isError set', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(result.isError, isNull);
    });

    test('returns three entries for the default changelog', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_entries(result), hasLength(3));
    });

    test('first entry version is 2.0.0', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_entries(result).first['version'], equals('2.0.0'));
    });

    test('entries are ordered newest-first', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));
      final versions = _entries(result).map((e) => e['version']).toList();

      expect(versions, equals(['2.0.0', '1.5.0', '1.0.0']));
    });

    test('breaking flag is true for an entry containing "breaking"', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_entries(result).first['breaking'], isTrue);
    });

    test('breaking flag is false for an entry without "breaking"', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_entries(result)[1]['breaking'], isFalse);
    });

    test('breaking detection is case-insensitive', () async {
      const html = '<h2>1.0.0</h2><p>BREAKING CHANGE: new API.</p>';
      _stubSuccess(mockHttp, html: html);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_entries(result).first['breaking'], isTrue);
    });

    test('parses ## 1.2.3 heading format', () async {
      const html = '<h2>3.0.0</h2><p>Changes.</p>';
      _stubSuccess(mockHttp, html: html);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_entries(result).first['version'], equals('3.0.0'));
    });

    test('parses ## [1.2.3] bracketed heading format', () async {
      _stubSuccess(mockHttp, html: _bracketedChangelogHtml);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_entries(result).first['version'], equals('2.0.0'));
    });

    test('bracketed format strips the brackets from the version string', () async {
      _stubSuccess(mockHttp, html: _bracketedChangelogHtml);

      final result = await buildHandler().call(_request({'package': 'http'}));
      final versions = _entries(result).map((e) => e['version']).toList();

      expect(versions, equals(['2.0.0', '1.0.0']));
    });

    test('both ## and ## [] formats coexist in one changelog', () async {
      const html = '''
<h2>[2.0.0]</h2><p>Breaking change.</p>
<h2>1.0.0</h2><p>Initial release.</p>
''';
      _stubSuccess(mockHttp, html: html);

      final result = await buildHandler().call(_request({'package': 'http'}));
      final versions = _entries(result).map((e) => e['version']).toList();

      expect(versions, equals(['2.0.0', '1.0.0']));
    });

    test('each entry includes a changes field as List<String>', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_entries(result).every((e) => e['changes'] is List), isTrue);
      expect(_entries(result).first['changes'], equals(['Breaking change: removed the old API.']));
    });

    test('each entry includes a rawText field as String', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_entries(result).every((e) => e['rawText'] is String), isTrue);
      expect(_entries(result).first['rawText'], equals('Breaking change: removed the old API.'));
    });

    test('parses ISO date from version heading', () async {
      const html = '<h2>2.0.0 - 2025-01-15</h2><p>Change notes.</p>';
      _stubSuccess(mockHttp, html: html);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_entries(result).first['date'], equals('2025-01-15T00:00:00.000Z'));
    });

    test('each entry includes a breaking field', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_entries(result).every((e) => e.containsKey('breaking')), isTrue);
    });
  });

  // ─── package echo ──────────────────────────────────────────────────────────

  group('package echo', () {
    test('is present and equals the requested package name', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_package(result), equals('http'));
    });
  });

  // ─── resolvedVersion (P1.11) ────────────────────────────────────────────────

  group('resolvedVersion', () {
    test('is present and equals the resolved latest stable version', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_resolvedVersion(result), equals('1.6.0'));
    });

    test('is emitted on a cache-hit response as well as a fresh fetch', () async {
      _stubSuccess(mockHttp);
      final handler = buildHandler();

      await handler.call(_request({'package': 'http'}));
      fakeNow = fakeNow.add(const Duration(minutes: 14));
      final result = await handler.call(_request({'package': 'http'}));

      expect(_resolvedVersion(result), equals('1.6.0'));
    });

    test('equals the caller-supplied version when version is given', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http', 'version': '1.5.0'}));

      expect(_resolvedVersion(result), equals('1.5.0'));
    });
  });

  // ─── version anchor ─────────────────────────────────────────────────────────

  group('version anchor', () {
    test('anchors changelog entries starting from the specified version', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'version': '1.5.0'}),
      );

      expect(result.isError, isNull);
      expect(_resolvedVersion(result), equals('1.5.0'));
      expect(
        _entries(result).map((e) => e['version']).toList(),
        equals(['1.5.0', '1.0.0']),
      );
    });

    test('anchors changelog with fromVersion', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'version': '1.5.0', 'fromVersion': '1.0.0'}),
      );

      expect(result.isError, isNull);
      expect(_resolvedVersion(result), equals('1.5.0'));
      expect(
        _entries(result).map((e) => e['version']).toList(),
        equals(['1.5.0']),
      );
    });

    test('returns invalidArgument when fromVersion is not older than version', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'version': '1.5.0', 'fromVersion': '2.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });
  });

  // ─── limit ────────────────────────────────────────────────────────────

  group('limit', () {
    test('defaults to 5 entries when limit is absent', () async {
      const html = '''
<h2>5.0.0</h2><p>v5.</p>
<h2>4.0.0</h2><p>v4.</p>
<h2>3.0.0</h2><p>v3.</p>
<h2>2.0.0</h2><p>v2.</p>
<h2>1.0.0</h2><p>v1.</p>
<h2>0.9.0</h2><p>v0.9.</p>
''';
      _stubSuccess(mockHttp, html: html);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_entries(result), hasLength(5));
    });

    test('caps entries at a custom limit', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'limit': 2}),
      );

      expect(_entries(result), hasLength(2));
    });

    test('returns all entries when limit exceeds the changelog size', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'limit': 100}),
      );

      expect(_entries(result), hasLength(3));
    });
  });

  // ─── no_documentation ────────────────────────────────────────────────────────

  group('no_documentation', () {
    test('returns isError true when changelog has no version headings', () async {
      _stubSuccess(mockHttp, html: _noHeadingsHtml);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(result.isError, isTrue);
    });

    test('error code is no_documentation when no headings found', () async {
      _stubSuccess(mockHttp, html: _noHeadingsHtml);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_errorPayload(result)['code'], equals(DomainErrors.noDocumentation));
    });

    test('error payload contains a suggestion', () async {
      _stubSuccess(mockHttp, html: _noHeadingsHtml);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  // ─── fromVersion found ───────────────────────────────────────────────────────

  group('fromVersion found in changelog', () {
    test('excludes the boundary version and returns newer entries', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'fromVersion': '1.5.0'}),
      );

      expect(
        _entries(result).map((e) => e['version']).toList(),
        equals(['2.0.0']),
      );
    });

    test('excludes the boundary version and all older entries', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'fromVersion': '1.0.0'}),
      );

      expect(
        _entries(result).map((e) => e['version']).toList(),
        equals(['2.0.0', '1.5.0']),
      );
    });

    test('returns empty list when fromVersion is the newest entry', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'fromVersion': '2.0.0'}),
      );

      expect(result.isError, isNull);
      expect(_entries(result), isEmpty);
    });

    test('limit is applied after fromVersion boundary', () async {
      const html = '''
<h2>4.0.0</h2><p>v4.</p>
<h2>3.0.0</h2><p>v3.</p>
<h2>2.0.0</h2><p>v2.</p>
<h2>1.0.0</h2><p>v1.</p>
''';
      _stubSuccess(mockHttp, html: html);

      final result = await buildHandler().call(
        _request({'package': 'http', 'fromVersion': '1.0.0', 'limit': 2}),
      );

      expect(
        _entries(result).map((e) => e['version']).toList(),
        equals(['4.0.0', '3.0.0']),
      );
    });
  });

  // ─── fromVersion not found ───────────────────────────────────────────────────

  group('fromVersion not found in changelog', () {
    test('uses next-older heading as boundary', () async {
      _stubSuccess(mockHttp);

      // 1.7.0 not in list; next-older is 1.5.0 → exclude 1.5.0 and 1.0.0
      final result = await buildHandler().call(
        _request({'package': 'http', 'fromVersion': '1.7.0'}),
      );

      expect(
        _entries(result).map((e) => e['version']).toList(),
        equals(['2.0.0']),
      );
    });

    test('returns invalid_input when no older heading exists', () async {
      _stubSuccess(mockHttp);

      // 0.1.0 is older than all entries
      final result = await buildHandler().call(
        _request({'package': 'http', 'fromVersion': '0.1.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('invalid_input error contains a suggestion', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'fromVersion': '0.1.0'}),
      );

      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  // ─── Cache hit ────────────────────────────────────────────────────────────────

  group('cache hit', () {
    test('does not issue a second HTTP request within the TTL window', () async {
      _stubSuccess(mockHttp);
      final handler = buildHandler();

      await handler.call(_request({'package': 'http'}));
      fakeNow = fakeNow.add(const Duration(minutes: 14));
      await handler.call(_request({'package': 'http'}));

      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/packages/http/changelog'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('cache hit applies fromVersion filter to cached entries', () async {
      _stubSuccess(mockHttp);
      final handler = buildHandler();

      await handler.call(_request({'package': 'http'}));
      fakeNow = fakeNow.add(const Duration(minutes: 14));
      final result = await handler.call(
        _request({'package': 'http', 'fromVersion': '1.5.0'}),
      );

      expect(result.isError, isNull);
      expect(
        _entries(result).map((e) => e['version']).toList(),
        equals(['2.0.0']),
      );
    });

    test('no_documentation result is cached so second call avoids HTTP', () async {
      _stubSuccess(mockHttp, html: _noHeadingsHtml);
      final handler = buildHandler();

      await handler.call(_request({'package': 'http'}));
      fakeNow = fakeNow.add(const Duration(minutes: 14));
      await handler.call(_request({'package': 'http'}));

      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/packages/http/changelog'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });
  });

  // ─── Cache miss ───────────────────────────────────────────────────────────────

  group('cache miss', () {
    test('logs an info HTTP-request message containing the package name', () async {
      _stubSuccess(mockHttp);

      await buildHandler().call(_request({'package': 'http'}));

      final infoLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.info)
          .map((m) => m.$2.toString());
      expect(infoLogs.any((m) => m.contains('package=http')), isTrue);
    });
  });

  // ─── Package not found ────────────────────────────────────────────────────────

  group('package not found', () {
    /// Stubs the resolve endpoint for 'unknown' to succeed (so the test
    /// exercises the changelog-404 path, not the resolve-404 path).
    void stubUnknownResolve() {
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/unknown',
        response: ok(
          '{"versions":[{"version":"1.0.0"}],"latest":{"version":"1.0.0"}}',
        ),
      );
    }

    test('returns isError true when the changelog page returns 404', () async {
      stubUnknownResolve();
      stubUrl(
        mock: mockHttp,
        urlFragment: '/packages/unknown/changelog',
        response: notFound(),
      );

      final result = await buildHandler().call(_request({'package': 'unknown'}));

      expect(result.isError, isTrue);
    });

    test('error code is package_not_found on 404', () async {
      stubUnknownResolve();
      stubUrl(
        mock: mockHttp,
        urlFragment: '/packages/unknown/changelog',
        response: notFound(),
      );

      final result = await buildHandler().call(_request({'package': 'unknown'}));

      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));
    });

    test('HTTP error result is not cached so the next call retries', () async {
      stubUnknownResolve();
      stubUrl(
        mock: mockHttp,
        urlFragment: '/packages/unknown/changelog',
        response: notFound(),
      );
      final handler = buildHandler();

      await handler.call(_request({'package': 'unknown'}));
      await handler.call(_request({'package': 'unknown'}));

      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/packages/unknown/changelog'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(greaterThan(1));
    });
  });

  // ─── Resolve failure (P1.17) ─────────────────────────────────────────────────
  //
  // The handler resolves the latest stable version before fetching the
  // changelog (to populate `resolvedVersion`). A failed resolution (404) must
  // propagate as package_not_found and short-circuit before the changelog
  // fetch. This is the inverse of the 'package not found' group above, which
  // stubs resolution to succeed and fails the changelog fetch instead.

  group('resolve failure', () {
    test('propagates package_not_found when version resolution returns 404', () async {
      stubUrl(mock: mockHttp, urlFragment: '/api/packages/http', response: notFound());

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));
    });

    test('does not fetch the changelog page when resolution fails', () async {
      stubUrl(mock: mockHttp, urlFragment: '/api/packages/http', response: notFound());

      await buildHandler().call(_request({'package': 'http'}));

      verifyNever(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/packages/http/changelog'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      );
    });
  });
}
