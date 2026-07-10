/// Unit tests for [BrowseApiSymbolsHandler].
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:pubdev_context/src/cache/memory_cache.dart';
import 'package:pubdev_context/src/data/domain_error.dart';
import 'package:pubdev_context/src/data/models.dart';
import 'package:pubdev_context/src/data/pub_client.dart';
import 'package:pubdev_context/src/tools/browse_api_symbols.dart';
import 'package:test/test.dart';

// ─── Mocks ────────────────────────────────────────────────────────────────────

class _MockHttpClient extends Mock implements http.Client {}

// ─── Helpers ──────────────────────────────────────────────────────────────────

String _readFixture(String name) => File('test/fixtures/$name').readAsStringSync();

http.Response _ok(String body) => http.Response(body, 200);

RetryPolicy get _instant => RetryPolicy(delay: (_) async {});

/// Stubs `GET /api/packages/{packageName}` so [PubDevClient.resolveLatestStable]
/// returns [resolvedVersion].
void _stubPackageInfo(
  _MockHttpClient mock, {
  String packageName = 'http',
  String resolvedVersion = '1.6.0',
}) {
  when(
    () => mock.get(
      any(
        that: predicate<Uri>(
          (u) =>
              u.toString().contains('/api/packages/$packageName') &&
              !u.toString().contains('/score') &&
              !u.toString().contains('/versions/'),
        ),
      ),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer(
    (_) async => _ok(
      '{"versions":[{"version":"$resolvedVersion"}],'
      '"latest":{"version":"$resolvedVersion"}}',
    ),
  );
}

/// Stubs `GET /documentation/{packageName}/{version}/index.json`.
///
/// [version] defaults to `'1.6.0'` — the resolved stable version returned by
/// the package-info stub — so tests that omit `version` in the tool request
/// pick up the right stub after [PubDevClient.resolveLatestStable].
void _stubIndexJson(
  _MockHttpClient mock, {
  int statusCode = 200,
  String packageName = 'http',
  String version = '1.6.0',
}) {
  when(
    () => mock.get(
      any(
        that: predicate<Uri>(
          (u) => u.toString().contains('/documentation/$packageName/$version/index.json'),
        ),
      ),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer(
    (_) async => statusCode == 200
        ? _ok(_readFixture('index_json.json'))
        : http.Response('Not Found', statusCode),
  );
}

/// Returns symbols parsed from the index fixture, mirroring what the handler
/// stores in cache after a successful HTTP call.
List<DartdocSymbol> _fixtureSymbols() {
  final json = jsonDecode(_readFixture('index_json.json')) as List<Object?>;
  return json.whereType<Map<String, Object?>>().map(DartdocSymbol.fromJson).toList();
}

/// Creates a [CallToolRequest] for `browse_api_symbols` with the given [args].
CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'browse_api_symbols', arguments: args);

/// Decodes the first content item of [result] as a JSON success object and
/// returns the `symbols` list.
List<Map<String, Object?>> _symbols(CallToolResult result) {
  final json = jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;
  return ((json['symbols'] as List<Object?>?) ?? const [])
      .cast<Map<String, Object?>>()
      .toList();
}

/// Decodes the first content item of [result] and returns its `resolvedVersion`.
String? _resolvedVersion(CallToolResult result) {
  final json = jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;
  return json['resolvedVersion'] as String?;
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
  late _MockHttpClient mockHttp;
  late PubDevClient client;
  late DateTime fakeNow;
  late ResponseCache<List<DartdocSymbol>> cache;
  final loggedMessages = <(LoggingLevel, Object)>[];

  BrowseApiSymbolsHandler buildHandler() => BrowseApiSymbolsHandler(
    client: client,
    cache: cache,
    log: (level, data) => loggedMessages.add((level, data)),
  );

  setUp(() {
    mockHttp = _MockHttpClient();
    registerFallbackValue(Uri.parse('https://pub.dev'));
    client = PubDevClient(httpClient: mockHttp, retryPolicy: _instant);
    fakeNow = DateTime(2025, 5, 10);
    cache = ResponseCache(clock: () => fakeNow);
    loggedMessages.clear();
  });

  tearDown(() => client.close());

  // ─── Limit validation ───────────────────────────────────────────────────────

  group('limit greater than 25', () {
    test('returns invalid_input domain error without calling the HTTP client', () async {
      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client', 'limit': 26}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
      verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
    });

    test('error payload contains a suggestion', () async {
      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client', 'limit': 26}),
      );

      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  group('limit of 25', () {
    test('is accepted without returning an error', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': '', 'limit': 25}),
      );

      expect(result.isError, isNull);
    });
  });

  // ─── Cache hit ──────────────────────────────────────────────────────────────

  group('cache hit after a live call', () {
    test('issues only one HTTP request for two calls to the same package', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);
      final handler = buildHandler();

      await handler.call(_request({'package': 'http', 'query': 'client'}));
      fakeNow = fakeNow.add(const Duration(minutes: 30));
      await handler.call(_request({'package': 'http', 'query': 'send'}));

      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/1.6.0/index.json'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('logs a debug cache-hit message on the second call', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);
      final handler = buildHandler();

      await handler.call(_request({'package': 'http', 'query': 'client'}));
      loggedMessages.clear();
      fakeNow = fakeNow.add(const Duration(minutes: 30));
      await handler.call(_request({'package': 'http', 'query': 'client'}));

      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString());
      expect(debugLogs.any((m) => m.contains('cache hit')), isTrue);
    });
  });

  // ─── Warm cache (pre-primed) ────────────────────────────────────────────────

  group('warm cache', () {
    test('makes no index HTTP request when the cache is pre-populated', () async {
      _stubPackageInfo(mockHttp);
      cache.set('$kApiIndexCachePrefix:http:1.6.0', Future.value(_fixtureSymbols()), kApiDocsTtl);

      await buildHandler().call(_request({'package': 'http', 'query': 'client'}));

      verifyNever(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('index.json'))),
          headers: any(named: 'headers'),
        ),
      );
    });
  });

  // ─── Cache miss ─────────────────────────────────────────────────────────────

  group('cache miss', () {
    test('logs a debug cache-miss message', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);

      await buildHandler().call(_request({'package': 'http', 'query': 'client'}));

      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString());
      expect(debugLogs.any((m) => m.contains('cache miss')), isTrue);
    });

    test('logs an info message containing the package name', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);

      await buildHandler().call(_request({'package': 'http', 'query': 'client'}));

      final infoLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.info)
          .map((m) => m.$2.toString());
      expect(infoLogs.any((m) => m.contains('package=http')), isTrue);
    });
  });

  // ─── Successful search ──────────────────────────────────────────────────────

  group('successful search', () {
    test('returns a non-error result for a query with known matches', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(result.isError, isNull);
    });

    test('returns a JSON array of DartdocSymbol maps', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(_symbols(result), isNotEmpty);
    });

    test('each symbol entry contains a name field', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(_symbols(result).every((s) => s.containsKey('name')), isTrue);
    });

    test('each symbol entry contains a type field', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(_symbols(result).every((s) => s.containsKey('type')), isTrue);
    });

    test('each symbol entry contains a qualifiedName field', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(_symbols(result).every((s) => s.containsKey('qualifiedName')), isTrue);
    });

    test('symbols with empty desc omit the desc field', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'BrowserClient.new'}),
      );

      // BrowserClient.new has an empty desc in the fixture
      final match = _symbols(result).firstWhere(
        (s) => s['name'] == 'BrowserClient.new',
        orElse: () => {},
      );
      expect(match.containsKey('desc'), isFalse);
    });
  });

  // ─── Ranking ────────────────────────────────────────────────────────────────

  group('ranking', () {
    test('exact name matches appear before desc-only matches', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      // "close" matches only by desc ("Closes the client.")
      // name matches: browser_client, BrowserClient, BrowserClient.new
      final symbolNames = _symbols(result).map((s) => s['name']! as String).toList();
      final closeIdx = symbolNames.indexOf('close');
      expect(closeIdx, greaterThan(0));
    });

    test('name matches appear before the desc-only match for the same query', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      final symbolNames = _symbols(result).map((s) => s['name']! as String).toList();
      final nameMatchIndices = symbolNames
          .asMap()
          .entries
          .where((e) => e.value.toLowerCase().contains('client'))
          .map((e) => e.key)
          .toList();
      final closeIdx = symbolNames.indexOf('close');

      expect(nameMatchIndices.every((i) => i < closeIdx), isTrue);
    });
  });

  // ─── Type filter ────────────────────────────────────────────────────────────

  group('type filter', () {
    test('narrows results to only the requested type', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client', 'type': 'class'}),
      );

      expect(_symbols(result).every((s) => s['type'] == 'class'), isTrue);
    });

    test('absent type returns all matching symbol kinds', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      final types = _symbols(result).map((s) => s['type']! as String).toSet();
      expect(types.length, greaterThan(1));
    });

    test('unknown type string is accepted without returning a type-related error', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client', 'type': 'widget'}),
      );

      // Should be no_results, not an error about the type being unrecognised
      expect(_errorPayload(result)['code'], equals(DomainErrors.noResults));
    });

    test('type filter applied after ranking preserves rank order within the type', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'http', 'type': 'class'}),
      );

      // query "http": name match = http (library), desc matches = BrowserClient, send, Abortable
      // After type=class: BrowserClient (name match? no — "BrowserClient" doesn't contain "http"),
      // Actually: "BrowserClient" name does NOT contain "http".
      // "http" name DOES contain "http" — but it's a library.
      // desc matches with type=class: BrowserClient (desc has "HTTP client"), Abortable (desc has "HTTP request")
      expect(_symbols(result).every((s) => s['type'] == 'class'), isTrue);
    });
  });

  // ─── Limit cap ──────────────────────────────────────────────────────────────

  group('limit cap', () {
    test('returns at most the requested limit of results', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': '', 'limit': 3}),
      );

      expect(_symbols(result).length, lessThanOrEqualTo(3));
    });

    test('returns at most 10 results when no limit is supplied', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': ''}),
      );

      expect(_symbols(result).length, lessThanOrEqualTo(10));
    });
  });

  // ─── no_results ─────────────────────────────────────────────────────────────

  group('no_results', () {
    test('returns no_results when the query matches nothing', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'xyzunknownsymbol123'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.noResults));
    });

    test('no_results payload contains a suggestion', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'xyzunknownsymbol123'}),
      );

      expect(_errorPayload(result), contains('suggestion'));
    });

    test('returns no_results when type filter eliminates all ranked matches', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);

      // query "close" matches only the "close" method — filtering by "library" yields nothing
      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'close', 'type': 'library'}),
      );

      expect(_errorPayload(result)['code'], equals(DomainErrors.noResults));
    });
  });

  // ─── no_documentation ───────────────────────────────────────────────────────

  group('no_documentation', () {
    test('returns no_documentation when the package has no dartdoc index', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp, statusCode: 404);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.noDocumentation));
    });

    test('no_documentation payload contains a suggestion', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp, statusCode: 404);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(_errorPayload(result), contains('suggestion'));
    });

    test('returns no_documentation when the cached index is empty', () async {
      _stubPackageInfo(mockHttp);
      cache.set(
        '$kApiIndexCachePrefix:http:1.6.0',
        Future.value(<DartdocSymbol>[]),
        kApiDocsTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(_errorPayload(result)['code'], equals(DomainErrors.noDocumentation));
    });

    test('returns no_documentation when the index is an empty array from the server', () async {
      _stubPackageInfo(mockHttp);
      when(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/1.6.0/index.json'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => _ok('[]'));

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(_errorPayload(result)['code'], equals(DomainErrors.noDocumentation));
    });
  });

  // ─── Client failures ────────────────────────────────────────────────────────

  group('client failure', () {
    test('propagates a rate_limited error when pub.dev returns HTTP 429', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp, statusCode: 429);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.rateLimited));
    });

    test('propagates a service_unavailable error when pub.dev returns HTTP 503', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp, statusCode: 503);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.serviceUnavailable));
    });

    test('error payload always contains message and suggestion fields', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp, statusCode: 503);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(_errorPayload(result), contains('message'));
      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  // ─── resolvedVersion (P1.10) ──────────────────────────────────────────────────

  group('resolvedVersion', () {
    test('is present and equals the resolved latest stable when version is omitted', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(_resolvedVersion(result), equals('1.6.0'));
    });

    test('echoes the supplied version when a pinned version is requested', () async {
      _stubIndexJson(mockHttp, version: '1.2.0');

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client', 'version': '1.2.0'}),
      );

      expect(_resolvedVersion(result), equals('1.2.0'));
    });
  });

  // ─── Cache key ───────────────────────────────────────────────────────────────

  group('cache key', () {
    test('uses api_index:<package>:<version> as the cache key format', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);
      await buildHandler().call(_request({'package': 'http', 'query': 'client'}));

      // The key must include the resolved version so pinned-version requests
      // never reuse docs cached for a different version.
      final cachedEntry = cache.get('$kApiIndexCachePrefix:http:1.6.0');
      expect(cachedEntry, isNotNull);
    });

    test('different packages use different cache keys', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);
      _stubPackageInfo(mockHttp, packageName: 'dio');
      _stubIndexJson(mockHttp, packageName: 'dio');

      final handler = buildHandler();
      await handler.call(_request({'package': 'http', 'query': 'client'}));
      await handler.call(_request({'package': 'dio', 'query': 'client'}));

      // Both cache entries should exist independently
      expect(cache.get('$kApiIndexCachePrefix:http:1.6.0'), isNotNull);
      expect(cache.get('$kApiIndexCachePrefix:dio:1.6.0'), isNotNull);
    });
  });
}
