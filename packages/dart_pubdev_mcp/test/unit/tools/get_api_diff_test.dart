/// Unit tests for [GetApiDiffHandler].
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:dart_pubdev_mcp/src/cache/cache_registry.dart';
import 'package:dart_pubdev_mcp/src/cache/keyed_cache.dart';
import 'package:dart_pubdev_mcp/src/data/domain_error.dart';
import 'package:dart_pubdev_mcp/src/data/models.dart';
import 'package:dart_pubdev_mcp/src/tools/get_api_diff.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';
import '../../support/pub_stubs.dart';

// ─── Helpers ──────────────────────────────────────────────────────────────────

/// Creates a [CallToolRequest] for `get_api_diff` with the given [args].
CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'get_api_diff', arguments: args);

/// Decodes the first content item of [result] as a JSON success object.
Map<String, Object?> _payload(CallToolResult result) =>
    jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;

/// Returns the `added`/`removed` bucket lists as `Set<String>` for order-free
/// membership assertions.
Set<String> _bucket(CallToolResult result, String side, String name) {
  final json = _payload(result);
  final sideMap = json[side]! as Map<String, Object?>;
  return ((sideMap[name] as List<Object?>?) ?? const []).cast<String>().toSet();
}

/// Decodes the first content item of [result] as a nested error payload.
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
  late DateTime fakeNow;
  late KeyedCache<ApiIndexId, List<DartdocSymbol>> apiIndex;
  final loggedMessages = <(LoggingLevel, Object)>[];

  GetApiDiffHandler buildHandler() => GetApiDiffHandler(
    apiIndex: apiIndex,
    log: (level, data) => loggedMessages.add((level, data)),
  );

  setUp(() {
    fakeNow = DateTime(2025, 5, 10);
    stack = TestStack(clock: () => fakeNow);
    mockHttp = stack.http;
    apiIndex = stack.caches.apiIndex;
    loggedMessages.clear();
  });

  tearDown(() => stack.close());

  /// Stubs both the from- and to-version indexes with the diff fixtures.
  void stubBothVersions() {
    stubIndexJson(mockHttp, version: '0.13.0', body: readFixture('api_diff_from.json'));
    stubIndexJson(mockHttp, version: '1.2.0', body: readFixture('api_diff_to.json'));
  }

  CallToolRequest diffRequest() =>
      _request({'package': 'http', 'fromVersion': '0.13.0', 'toVersion': '1.2.0'});

  // ─── Argument validation ──────────────────────────────────────────────────────

  group('argument validation', () {
    test('returns INVALID_ARGUMENT when fromVersion is omitted', () async {
      final result = await buildHandler().call(
        _request({'package': 'http', 'toVersion': '1.2.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
      verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
    });

    test('returns INVALID_ARGUMENT when toVersion is omitted', () async {
      final result = await buildHandler().call(
        _request({'package': 'http', 'fromVersion': '0.13.0'}),
      );

      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('returns INVALID_ARGUMENT when package is omitted', () async {
      final result = await buildHandler().call(
        _request({'fromVersion': '0.13.0', 'toVersion': '1.2.0'}),
      );

      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('validation error carries a suggestion', () async {
      final result = await buildHandler().call(
        _request({'package': 'http', 'toVersion': '1.2.0'}),
      );

      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  // ─── Diff computation ─────────────────────────────────────────────────────────

  group('added symbols', () {
    test('reports a newly added library', () async {
      stubBothVersions();
      final result = await buildHandler().call(diffRequest());

      expect(_bucket(result, 'added', 'libraries'), equals({'http.io'}));
    });

    test('reports a newly added class', () async {
      stubBothVersions();
      final result = await buildHandler().call(diffRequest());

      expect(_bucket(result, 'added', 'classes'), equals({'http.NewClient'}));
    });

    test('reports a newly added method', () async {
      stubBothVersions();
      final result = await buildHandler().call(diffRequest());

      expect(_bucket(result, 'added', 'methods'), equals({'http.Client.close'}));
    });

    test('reports a newly added field', () async {
      stubBothVersions();
      final result = await buildHandler().call(diffRequest());

      expect(_bucket(result, 'added', 'fields'), equals({'http.Client.maxRedirects'}));
    });
  });

  group('removed symbols', () {
    test('reports a removed class', () async {
      stubBothVersions();
      final result = await buildHandler().call(diffRequest());

      expect(_bucket(result, 'removed', 'classes'), equals({'http.OldClient'}));
    });

    test('reports a removed field', () async {
      stubBothVersions();
      final result = await buildHandler().call(diffRequest());

      expect(_bucket(result, 'removed', 'fields'), equals({'http.Client.timeout'}));
    });

    test('leaves libraries and methods buckets empty when nothing was removed', () async {
      stubBothVersions();
      final result = await buildHandler().call(diffRequest());

      expect(_bucket(result, 'removed', 'libraries'), isEmpty);
      expect(_bucket(result, 'removed', 'methods'), isEmpty);
    });
  });

  group('symbols present in both versions', () {
    test('are reported in neither added nor removed', () async {
      stubBothVersions();
      final result = await buildHandler().call(diffRequest());

      // http, http.Client, http.Client.send are unchanged across versions.
      final allAdded = [
        ..._bucket(result, 'added', 'libraries'),
        ..._bucket(result, 'added', 'classes'),
        ..._bucket(result, 'added', 'methods'),
        ..._bucket(result, 'added', 'fields'),
      ];
      final allRemoved = [
        ..._bucket(result, 'removed', 'libraries'),
        ..._bucket(result, 'removed', 'classes'),
        ..._bucket(result, 'removed', 'methods'),
        ..._bucket(result, 'removed', 'fields'),
      ];
      expect(allAdded, isNot(contains('http.Client')));
      expect(allRemoved, isNot(contains('http.Client')));
      expect(allAdded, isNot(contains('http.Client.send')));
    });
  });

  // ─── Response shape ───────────────────────────────────────────────────────────

  group('response shape', () {
    test('echoes package, fromVersion, and toVersion (no resolvedVersion field)', () async {
      stubBothVersions();
      final result = await buildHandler().call(diffRequest());
      final json = _payload(result);

      expect(json['package'], equals('http'));
      expect(json['fromVersion'], equals('0.13.0'));
      expect(json['toVersion'], equals('1.2.0'));
      expect(json.containsKey('resolvedVersion'), isFalse);
    });

    test('added and removed each contain all four bucket keys', () async {
      stubBothVersions();
      final result = await buildHandler().call(diffRequest());
      final json = _payload(result);

      for (final side in ['added', 'removed']) {
        final map = json[side]! as Map<String, Object?>;
        expect(map.keys, containsAll(['libraries', 'classes', 'methods', 'fields']));
      }
    });

    test('is not an error result', () async {
      stubBothVersions();
      final result = await buildHandler().call(diffRequest());

      expect(result.isError, isNull);
    });
  });

  // ─── Missing documentation ────────────────────────────────────────────────────

  group('missing documentation', () {
    test('returns DOCUMENTATION_NOT_FOUND when fromVersion docs are missing', () async {
      stubIndexJson(
        mockHttp,
        version: '0.13.0',
        body: readFixture('api_diff_from.json'),
        statusCode: 404,
      );
      stubIndexJson(mockHttp, version: '1.2.0', body: readFixture('api_diff_to.json'));

      final result = await buildHandler().call(diffRequest());

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.documentationNotFound));
    });

    test('returns DOCUMENTATION_NOT_FOUND when toVersion docs are missing', () async {
      stubIndexJson(mockHttp, version: '0.13.0', body: readFixture('api_diff_from.json'));
      stubIndexJson(
        mockHttp,
        version: '1.2.0',
        body: readFixture('api_diff_to.json'),
        statusCode: 404,
      );

      final result = await buildHandler().call(diffRequest());

      expect(_errorPayload(result)['code'], equals(DomainErrors.documentationNotFound));
    });

    test('returns DOCUMENTATION_NOT_FOUND when a version index is an empty array', () async {
      when(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/0.13.0/index.json'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => ok('[]'));
      stubIndexJson(mockHttp, version: '1.2.0', body: readFixture('api_diff_to.json'));

      final result = await buildHandler().call(diffRequest());

      expect(_errorPayload(result)['code'], equals(DomainErrors.documentationNotFound));
    });

    test('error names the offending version in suggestedNextStep', () async {
      stubIndexJson(
        mockHttp,
        version: '0.13.0',
        body: readFixture('api_diff_from.json'),
        statusCode: 404,
      );
      stubIndexJson(mockHttp, version: '1.2.0', body: readFixture('api_diff_to.json'));

      final result = await buildHandler().call(diffRequest());
      final next = _errorPayload(result)['suggestedNextStep']! as Map<String, Object?>;

      expect(next['tool'], equals('browse_api_symbols'));
      final args = next['arguments']! as Map<String, Object?>;
      expect(args['package'], equals('http'));
      expect(args['version'], equals('0.13.0'));
    });
  });

  // ─── Transient failures ───────────────────────────────────────────────────────

  group('transient client failure', () {
    test('propagates RATE_LIMITED rather than masking it as missing docs', () async {
      stubIndexJson(
        mockHttp,
        version: '0.13.0',
        body: readFixture('api_diff_from.json'),
        statusCode: 429,
      );
      stubIndexJson(mockHttp, version: '1.2.0', body: readFixture('api_diff_to.json'));

      final result = await buildHandler().call(diffRequest());

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.rateLimited));
    });
  });

  // ─── Caching ──────────────────────────────────────────────────────────────────

  group('caching', () {
    test('caches both version indexes in the shared apiIndex facade', () async {
      stubBothVersions();
      await buildHandler().call(diffRequest());

      expect(await apiIndex.peek((name: 'http', version: '0.13.0')), isNotNull);
      expect(await apiIndex.peek((name: 'http', version: '1.2.0')), isNotNull);
    });

    test('reuses a warm cache entry without issuing an HTTP request', () async {
      // Only the from-version needs a live fetch; the to-version is already warm.
      stubIndexJson(mockHttp, version: '0.13.0', body: readFixture('api_diff_from.json'));
      stubIndexJson(mockHttp, version: '1.2.0', body: readFixture('api_diff_to.json'));
      await apiIndex.resolve((name: 'http', version: '1.2.0'));

      final result = await buildHandler().call(diffRequest());

      expect(result.isError, isNull);
      // Exactly the warm-up fetch above — the diff request itself was a hit.
      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/1.2.0/index.json'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('a second diff over the same versions issues no further HTTP requests', () async {
      stubBothVersions();
      final handler = buildHandler();

      await handler.call(diffRequest());
      // A second diff over the same versions must not re-fetch either index.
      await handler.call(diffRequest());

      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/0.13.0/index.json'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });
  });
}
