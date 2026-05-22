/// Unit tests for [GetSymbolDocumentationHandler].
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
import 'package:pubdev_context/src/tools/get_symbol_documentation.dart';
import 'package:test/test.dart';

// ─── Mocks ────────────────────────────────────────────────────────────────────

class _MockHttpClient extends Mock implements http.Client {}

// ─── Fixtures ─────────────────────────────────────────────────────────────────

String _readFixture(String name) => File('test/fixtures/$name').readAsStringSync();

http.Response _ok(String body) => http.Response(body, 200);

RetryPolicy get _instant => RetryPolicy(delay: (_) async {});

// ─── HTTP stub helpers ─────────────────────────────────────────────────────────

/// Stubs `GET /documentation/<package>/latest/index.json` (or [version]).
void _stubIndexJson(
  _MockHttpClient mock, {
  int statusCode = 200,
  String packageName = 'http',
  String version = 'latest',
  String? body,
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
        ? _ok(body ?? _readFixture('index_json.json'))
        : http.Response('Not Found', statusCode),
  );
}

/// Stubs `GET /documentation/<package>/latest/<href>` (or [version]).
void _stubSymbolDoc(
  _MockHttpClient mock, {
  required String href,
  int statusCode = 200,
  String packageName = 'http',
  String version = 'latest',
}) {
  when(
    () => mock.get(
      any(
        that: predicate<Uri>(
          (u) => u.toString().contains('/documentation/$packageName/$version/$href'),
        ),
      ),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer(
    (_) async => statusCode == 200
        ? _ok(_readFixture('symbol_doc.html'))
        : http.Response('Not Found', statusCode),
  );
}

// ─── Test symbol helpers ───────────────────────────────────────────────────────

/// Creates a minimal [DartdocSymbol] for test use.
DartdocSymbol _sym({
  required String name,
  required String qualifiedName,
  required String href,
  String type = 'method',
  String desc = '',
}) => DartdocSymbol(
  name: name,
  qualifiedName: qualifiedName,
  href: href,
  type: type,
  desc: desc,
);

/// A [DartdocSymbol] for `Client` (class, in the http library).
final DartdocSymbol _clientClass = _sym(
  name: 'Client',
  qualifiedName: 'http.Client',
  href: 'http/Client-class.html',
  type: 'class',
);

/// A [DartdocSymbol] for `Client.send` (method).
final DartdocSymbol _clientSend = _sym(
  name: 'send',
  qualifiedName: 'http.Client.send',
  href: 'http/Client/send.html',
);

// ─── Request / result helpers ──────────────────────────────────────────────────

/// Creates a [CallToolRequest] for `get_symbol_documentation` with the given [args].
CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'get_symbol_documentation', arguments: args);

/// Decodes the first content item of [result] as a JSON error payload.
Map<String, Object?> _errorPayload(CallToolResult result) =>
    jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;

/// Returns the plain-text content from the first content item of [result].
String _text(CallToolResult result) => (result.content.first as TextContent).text;

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late _MockHttpClient mockHttp;
  late PubDevClient client;
  late DateTime fakeNow;
  late ResponseCache<String> symbolDocCache;
  late ResponseCache<List<DartdocSymbol>> apiIndexCache;
  final loggedMessages = <(LoggingLevel, Object)>[];

  GetSymbolDocumentationHandler buildHandler() => GetSymbolDocumentationHandler(
    client: client,
    cache: symbolDocCache,
    apiIndexCache: apiIndexCache,
    log: (level, data) => loggedMessages.add((level, data)),
  );

  setUp(() {
    mockHttp = _MockHttpClient();
    registerFallbackValue(Uri.parse('https://pub.dev'));
    client = PubDevClient(httpClient: mockHttp, retryPolicy: _instant);
    fakeNow = DateTime(2025, 5, 10);
    symbolDocCache = ResponseCache(clock: () => fakeNow);
    apiIndexCache = ResponseCache(clock: () => fakeNow);
    loggedMessages.clear();
  });

  tearDown(() => client.close());

  // ─── Pass 1: exact name match ───────────────────────────────────────────────

  group('pass 1 — exact name match', () {
    test('resolves a single exact name match and returns documentation', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([_clientClass]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(result.isError, isNull);
      expect(_text(result), isNotEmpty);
    });

    test('returns non-empty plain-text content on a pass 1 hit', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([_clientClass]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(_text(result), isNotEmpty);
    });

    test('makes exactly one HTTP request for the symbol doc on a pass 1 hit', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([_clientClass]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      await buildHandler().call(_request({'package': 'http', 'symbol': 'Client'}));

      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/latest/http/Client-class.html'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });
  });

  // ─── Pass 2: qualifiedName suffix match ─────────────────────────────────────

  group('pass 2 — qualifiedName suffix match', () {
    test('resolves "Client.send" via suffix match to the method href', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([_clientClass, _clientSend]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, href: 'http/Client/send.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client.send'}),
      );

      expect(result.isError, isNull);
      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/latest/http/Client/send.html'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('ignores symbols whose qualifiedName has no dot separator in pass 2', () async {
      final library = _sym(
        name: 'http',
        qualifiedName: 'http', // no dot — must not match anything
        href: 'http/',
        type: 'library',
      );
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([library, _clientSend]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, href: 'http/Client/send.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client.send'}),
      );

      // Should resolve to _clientSend via suffix match, not error.
      expect(result.isError, isNull);
    });
  });

  // ─── Pass 0: exact qualifiedName match (ambiguous_symbol retry path) ──────────

  group('pass 0 — exact qualifiedName match', () {
    test('resolves "http.Client" to the class href (retry after ambiguous_symbol)', () async {
      final classA = _sym(
        name: 'Client',
        qualifiedName: 'http.Client',
        href: 'http/Client-class.html',
        type: 'class',
      );
      final classB = _sym(
        name: 'Client',
        qualifiedName: 'browser_client.Client',
        href: 'browser_client/Client-class.html',
        type: 'class',
      );
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([classA, classB]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      // First call returns ambiguous_symbol; simulated retry passes the
      // qualifiedName directly.
      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'http.Client'}),
      );

      expect(result.isError, isNull);
      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('http/Client-class.html'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('resolves "browser_client.Client" to the correct href', () async {
      final classA = _sym(
        name: 'Client',
        qualifiedName: 'http.Client',
        href: 'http/Client-class.html',
        type: 'class',
      );
      final classB = _sym(
        name: 'Client',
        qualifiedName: 'browser_client.Client',
        href: 'browser_client/Client-class.html',
        type: 'class',
      );
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([classA, classB]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, href: 'browser_client/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'browser_client.Client'}),
      );

      expect(result.isError, isNull);
      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('browser_client/Client-class.html'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('pass 0 takes priority over pass 1 for the same symbol', () async {
      // qualifiedName 'http.Client' would also match pass 1 (name == 'Client'
      // for a different entry) — pass 0 should resolve it first and unambiguously.
      final classA = _sym(
        name: 'Client',
        qualifiedName: 'http.Client',
        href: 'http/Client-class.html',
        type: 'class',
      );
      final classB = _sym(
        name: 'Client',
        qualifiedName: 'browser_client.Client',
        href: 'browser_client/Client-class.html',
        type: 'class',
      );
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([classA, classB]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      // 'http.Client' has an exact qualifiedName match — must resolve without
      // going to pass 1 (which would see two 'Client' name matches and
      // return ambiguous_symbol).
      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'http.Client'}),
      );

      expect(result.isError, isNull);
    });

    test('end-to-end ambiguous_symbol retry succeeds', () async {
      final classA = _sym(
        name: 'Client',
        qualifiedName: 'http.Client',
        href: 'http/Client-class.html',
        type: 'class',
      );
      final classB = _sym(
        name: 'Client',
        qualifiedName: 'browser_client.Client',
        href: 'browser_client/Client-class.html',
        type: 'class',
      );
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([classA, classB]),
        kApiDocsTtl,
      );

      final handler = buildHandler();

      // Initial call — ambiguous.
      final first = await handler.call(_request({'package': 'http', 'symbol': 'Client'}));
      expect(first.isError, isTrue);
      expect(_errorPayload(first)['error'], equals(DomainErrors.ambiguousSymbol));

      // Pick the first alternative and retry.
      final alternatives =
          (_errorPayload(first)['alternatives']! as List<Object?>).cast<String>();
      final retrySymbol = alternatives.first;

      final expectedHref = retrySymbol == 'http.Client'
          ? 'http/Client-class.html'
          : 'browser_client/Client-class.html';
      _stubSymbolDoc(mockHttp, href: expectedHref);

      final second = await handler.call(
        _request({'package': 'http', 'symbol': retrySymbol}),
      );

      expect(second.isError, isNull);
    });
  });

  // ─── Disambiguation ─────────────────────────────────────────────────────────

  group('disambiguation', () {
    test('prefers the sole class entry when multiple name matches exist', () async {
      final closeMethod = _sym(
        name: 'Client',
        qualifiedName: 'http.Client.Client',
        href: 'http/Client/Client.html',
        type: 'constructor',
      );
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([_clientClass, closeMethod]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(result.isError, isNull);
      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('http/Client-class.html'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('returns ambiguous_symbol when multiple class entries match', () async {
      final classA = _sym(
        name: 'Client',
        qualifiedName: 'http.Client',
        href: 'http/Client-class.html',
        type: 'class',
      );
      final classB = _sym(
        name: 'Client',
        qualifiedName: 'browser_client.Client',
        href: 'browser_client/Client-class.html',
        type: 'class',
      );
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([classA, classB]),
        kApiDocsTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['error'], equals(DomainErrors.ambiguousSymbol));
    });

    test('ambiguous_symbol payload includes alternatives array', () async {
      final classA = _sym(
        name: 'Client',
        qualifiedName: 'http.Client',
        href: 'http/Client-class.html',
        type: 'class',
      );
      final classB = _sym(
        name: 'Client',
        qualifiedName: 'browser_client.Client',
        href: 'browser_client/Client-class.html',
        type: 'class',
      );
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([classA, classB]),
        kApiDocsTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      final payload = _errorPayload(result);
      expect(payload['alternatives'], isA<List<Object?>>());
      expect(
        (payload['alternatives']! as List<Object?>).cast<String>(),
        containsAll(['http.Client', 'browser_client.Client']),
      );
    });

    test('returns ambiguous_symbol when multiple matches have no class entry', () async {
      final methodA = _sym(
        name: 'close',
        qualifiedName: 'http.Client.close',
        href: 'http/Client/close.html',
      );
      final methodB = _sym(
        name: 'close',
        qualifiedName: 'browser_client.BrowserClient.close',
        href: 'browser_client/BrowserClient/close.html',
      );
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([methodA, methodB]),
        kApiDocsTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'close'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['error'], equals(DomainErrors.ambiguousSymbol));
    });

    test('ambiguous_symbol payload contains message and suggestion', () async {
      final classA = _sym(
        name: 'Client',
        qualifiedName: 'http.Client',
        href: 'http/Client-class.html',
        type: 'class',
      );
      final classB = _sym(
        name: 'Client',
        qualifiedName: 'browser_client.Client',
        href: 'browser_client/Client-class.html',
        type: 'class',
      );
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([classA, classB]),
        kApiDocsTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(_errorPayload(result), contains('message'));
      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  // ─── symbol_not_found ───────────────────────────────────────────────────────

  group('symbol_not_found', () {
    test('returns symbol_not_found when symbol is absent from the index', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([_clientClass]),
        kApiDocsTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'NonExistentSymbol'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['error'], equals(DomainErrors.symbolNotFound));
    });

    test('returns symbol_not_found when the resolved href returns HTTP 404', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([_clientClass]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, statusCode: 404, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['error'], equals(DomainErrors.symbolNotFound));
    });

    test('symbol_not_found payload contains message and suggestion', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([_clientClass]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, statusCode: 404, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(_errorPayload(result), contains('message'));
      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  // ─── no_documentation ───────────────────────────────────────────────────────

  group('no_documentation', () {
    test('returns no_documentation when the API index is empty', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value(<DartdocSymbol>[]),
        kApiDocsTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['error'], equals(DomainErrors.noDocumentation));
    });

    test('returns no_documentation when the index endpoint returns 404', () async {
      _stubIndexJson(mockHttp, statusCode: 404);

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['error'], equals(DomainErrors.noDocumentation));
    });
  });

  // ─── Index cache behavior ───────────────────────────────────────────────────

  group('API index cache', () {
    test('uses index cache hit without issuing an HTTP request for the index', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([_clientClass]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      await buildHandler().call(_request({'package': 'http', 'symbol': 'Client'}));

      verifyNever(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('index.json'))),
          headers: any(named: 'headers'),
        ),
      );
    });

    test('shares the API index cache key with browse_api_symbols (api_index:<package>)', () async {
      _stubIndexJson(mockHttp);
      _stubSymbolDoc(mockHttp, href: 'browser_client/BrowserClient-class.html');

      await buildHandler().call(
        _request({'package': 'http', 'symbol': 'BrowserClient'}),
      );

      // The api_index cache should now be warmed under the browse_api_symbols key.
      final cached = apiIndexCache.get('$kApiIndexCachePrefix:http');
      expect(cached, isNotNull);
    });

    test('logs a debug cache-hit message when the index is warm', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([_clientClass]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      await buildHandler().call(_request({'package': 'http', 'symbol': 'Client'}));

      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString());
      expect(debugLogs.any((m) => m.contains('index cache hit')), isTrue);
    });

    test('logs a debug cache-miss message on an index fetch', () async {
      _stubIndexJson(mockHttp);
      _stubSymbolDoc(mockHttp, href: 'browser_client/BrowserClient-class.html');

      await buildHandler().call(
        _request({'package': 'http', 'symbol': 'BrowserClient'}),
      );

      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString());
      expect(debugLogs.any((m) => m.contains('index cache miss')), isTrue);
    });
  });

  // ─── Symbol doc cache behavior ──────────────────────────────────────────────

  group('symbol doc cache', () {
    test('issues only one doc HTTP request for two calls resolving to the same href', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([_clientClass]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');
      final handler = buildHandler();

      await handler.call(_request({'package': 'http', 'symbol': 'Client'}));
      fakeNow = fakeNow.add(const Duration(minutes: 30));
      await handler.call(_request({'package': 'http', 'symbol': 'Client'}));

      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/latest/http/Client-class.html'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('logs a doc cache-hit message on the second call', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([_clientClass]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');
      final handler = buildHandler();

      await handler.call(_request({'package': 'http', 'symbol': 'Client'}));
      loggedMessages.clear();
      fakeNow = fakeNow.add(const Duration(minutes: 30));
      await handler.call(_request({'package': 'http', 'symbol': 'Client'}));

      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString());
      expect(debugLogs.any((m) => m.contains('doc cache hit')), isTrue);
    });

    test('symbol doc cache key uses symbol_doc:<package>:<version>:<href> format', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([_clientClass]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      await buildHandler().call(_request({'package': 'http', 'symbol': 'Client'}));

      final cacheEntry = symbolDocCache.get(
        '$kSymbolDocCachePrefix:http:latest:http/Client-class.html',
      );
      expect(cacheEntry, isNotNull);
    });

    test('returns symbol_not_found when the cached symbol doc entry is empty', () async {
      symbolDocCache.set(
        '$kSymbolDocCachePrefix:http:latest:http/Client-class.html',
        Future.value(''),
        kSymbolDocTtl,
      );
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([_clientClass]),
        kApiDocsTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['error'], equals(DomainErrors.symbolNotFound));
    });
  });

  // ─── Symbol doc cache — version isolation ──────────────────────────────────

  group('symbol doc cache — version isolation', () {
    test('pinned-version request populates a separate cache entry from latest', () async {
      apiIndexCache
        ..set('$kApiIndexCachePrefix:http', Future.value([_clientClass]), kApiDocsTtl)
        ..set('$kApiIndexCachePrefix:http:1.0.0', Future.value([_clientClass]), kApiDocsTtl);
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html', version: '1.0.0');
      final handler = buildHandler();

      await handler.call(_request({'package': 'http', 'symbol': 'Client'}));
      await handler.call(
        _request({'package': 'http', 'symbol': 'Client', 'version': '1.0.0'}),
      );

      expect(
        symbolDocCache.get('$kSymbolDocCachePrefix:http:latest:http/Client-class.html'),
        isNotNull,
      );
      expect(
        symbolDocCache.get('$kSymbolDocCachePrefix:http:1.0.0:http/Client-class.html'),
        isNotNull,
      );
    });

    test('different versions issue separate HTTP doc requests', () async {
      apiIndexCache
        ..set('$kApiIndexCachePrefix:http', Future.value([_clientClass]), kApiDocsTtl)
        ..set('$kApiIndexCachePrefix:http:1.0.0', Future.value([_clientClass]), kApiDocsTtl);
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html', version: '1.0.0');
      final handler = buildHandler();

      await handler.call(_request({'package': 'http', 'symbol': 'Client'}));
      await handler.call(
        _request({'package': 'http', 'symbol': 'Client', 'version': '1.0.0'}),
      );

      // Both versions must have triggered a distinct HTTP request.
      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/latest/http/Client-class.html'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/1.0.0/http/Client-class.html'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('a cached 404 from one version does not block a valid request for another', () async {
      // Pre-populate a symbol_not_found sentinel for version '3.0.0'.
      symbolDocCache.set(
        '$kSymbolDocCachePrefix:http:3.0.0:http/Client-class.html',
        Future.value(''), // empty sentinel = symbol_not_found
        kSymbolDocTtl,
      );
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http:2.0.0',
        Future.value([_clientClass]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html', version: '2.0.0');

      // A request for '2.0.0' must not be blocked by the '3.0.0' sentinel.
      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client', 'version': '2.0.0'}),
      );

      expect(result.isError, isNull);
    });
  });

  // ─── Client failures ────────────────────────────────────────────────────────

  group('client failure (doc fetch)', () {
    test('propagates rate_limited when the symbol doc page returns HTTP 429', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([_clientClass]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, statusCode: 429, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['error'], equals(DomainErrors.rateLimited));
    });

    test('propagates service_unavailable when the symbol doc page returns HTTP 503', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([_clientClass]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, statusCode: 503, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['error'], equals(DomainErrors.serviceUnavailable));
    });

    test('error payload always contains message and suggestion fields', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([_clientClass]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, statusCode: 503, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(_errorPayload(result), contains('message'));
      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  // ─── version parameter ──────────────────────────────────────────────────────

  group('version parameter', () {
    test('uses the specified version in the index URL', () async {
      _stubIndexJson(mockHttp, version: '1.2.0');
      _stubSymbolDoc(mockHttp, href: 'browser_client/BrowserClient-class.html', version: '1.2.0');

      await buildHandler().call(
        _request({'package': 'http', 'symbol': 'BrowserClient', 'version': '1.2.0'}),
      );

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

    test('uses the specified version in the symbol doc URL', () async {
      _stubIndexJson(mockHttp, version: '1.2.0');
      _stubSymbolDoc(mockHttp, href: 'browser_client/BrowserClient-class.html', version: '1.2.0');

      await buildHandler().call(
        _request({'package': 'http', 'symbol': 'BrowserClient', 'version': '1.2.0'}),
      );

      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) =>
                  u.toString().contains('/documentation/http/1.2.0/') &&
                  u.toString().contains('BrowserClient'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(greaterThanOrEqualTo(1));
    });

    test('uses a separate index cache key for a pinned version', () async {
      _stubIndexJson(mockHttp, version: '1.2.0');
      _stubSymbolDoc(mockHttp, href: 'browser_client/BrowserClient-class.html', version: '1.2.0');

      await buildHandler().call(
        _request({'package': 'http', 'symbol': 'BrowserClient', 'version': '1.2.0'}),
      );

      expect(apiIndexCache.get('$kApiIndexCachePrefix:http:1.2.0'), isNotNull);
      expect(apiIndexCache.get('$kApiIndexCachePrefix:http'), isNull);
    });

    test('omitting version defaults to latest in both URLs', () async {
      _stubIndexJson(mockHttp);
      _stubSymbolDoc(mockHttp, href: 'browser_client/BrowserClient-class.html');

      await buildHandler().call(
        _request({'package': 'http', 'symbol': 'BrowserClient'}),
      );

      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/latest/index.json'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });
  });

  // ─── HTML processing ─────────────────────────────────────────────────────────

  group('HTML processing', () {
    test('strips HTML tags from the returned content', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([_clientClass]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(_text(result), isNot(contains('<html')));
      expect(_text(result), isNot(contains('<body')));
    });

    test('decodes HTML entities in the returned content', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([_clientClass]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      // Fixture contains &lt; and &gt; — these should be decoded to < and >.
      expect(_text(result), contains('<'));
      expect(_text(result), contains('>'));
    });

    test('result contains recognisable symbol content from the fixture', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:http',
        Future.value([_clientClass]),
        kApiDocsTtl,
      );
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(_text(result), contains('Client'));
    });
  });
}
