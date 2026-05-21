/// Unit tests for [GetSymbolDocumentationHandler].
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:pubdev_context/src/cache/memory_cache.dart';
import 'package:pubdev_context/src/data/domain_error.dart';
import 'package:pubdev_context/src/data/pub_client.dart';
import 'package:pubdev_context/src/tools/get_symbol_documentation.dart';
import 'package:test/test.dart';

// ─── Mocks ────────────────────────────────────────────────────────────────────

class _MockHttpClient extends Mock implements http.Client {}

// ─── Helpers ──────────────────────────────────────────────────────────────────

String _readFixture(String name) => File('test/fixtures/$name').readAsStringSync();

http.Response _ok(String body) => http.Response(body, 200);

RetryPolicy get _instant => RetryPolicy(delay: (_) async {});

void _stubSymbolDoc(
  _MockHttpClient mock, {
  int statusCode = 200,
  String packageName = 'http',
  String href = 'http/Client-class.html',
}) {
  when(
    () => mock.get(
      any(
        that: predicate<Uri>(
          (u) => u.toString().contains('/documentation/$packageName/latest/$href'),
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
  late ResponseCache<String> cache;
  final loggedMessages = <(LoggingLevel, Object)>[];

  GetSymbolDocumentationHandler buildHandler() => GetSymbolDocumentationHandler(
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

  // ─── Successful fetch ───────────────────────────────────────────────────────

  group('successful fetch', () {
    test('returns a non-error result for a valid package and href', () async {
      _stubSymbolDoc(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'href': 'http/Client-class.html'}),
      );

      expect(result.isError, isNull);
    });

    test('returns non-empty plain-text content', () async {
      _stubSymbolDoc(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'href': 'http/Client-class.html'}),
      );

      expect(_text(result), isNotEmpty);
    });

    test('strips HTML tags from the returned content', () async {
      _stubSymbolDoc(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'href': 'http/Client-class.html'}),
      );

      expect(_text(result), isNot(contains('<html')));
      expect(_text(result), isNot(contains('<body')));
    });

    test('decodes HTML entities in the returned content', () async {
      _stubSymbolDoc(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'href': 'http/Client-class.html'}),
      );

      // fixture contains &lt; and &gt; — these should be decoded to < and >
      expect(_text(result), contains('<'));
      expect(_text(result), contains('>'));
    });

    test('result contains recognisable symbol content from the fixture', () async {
      _stubSymbolDoc(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'href': 'http/Client-class.html'}),
      );

      expect(_text(result), contains('Client'));
    });
  });

  // ─── Cache hit ──────────────────────────────────────────────────────────────

  group('cache hit after a live call', () {
    test('issues only one HTTP request for two calls to the same package and href', () async {
      _stubSymbolDoc(mockHttp);
      final handler = buildHandler();

      await handler.call(_request({'package': 'http', 'href': 'http/Client-class.html'}));
      fakeNow = fakeNow.add(const Duration(minutes: 30));
      await handler.call(_request({'package': 'http', 'href': 'http/Client-class.html'}));

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

    test('logs a debug cache-hit message on the second call', () async {
      _stubSymbolDoc(mockHttp);
      final handler = buildHandler();

      await handler.call(_request({'package': 'http', 'href': 'http/Client-class.html'}));
      loggedMessages.clear();
      fakeNow = fakeNow.add(const Duration(minutes: 30));
      await handler.call(_request({'package': 'http', 'href': 'http/Client-class.html'}));

      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString());
      expect(debugLogs.any((m) => m.contains('cache hit')), isTrue);
    });

    test('returns symbol_not_found when the cached entry is empty', () async {
      cache.set(
        '$kSymbolDocCachePrefix:http:http/Client-class.html',
        Future.value(''),
        kSymbolDocTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'http', 'href': 'http/Client-class.html'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['error'], equals(DomainErrors.symbolNotFound));
    });
  });

  // ─── Warm cache ─────────────────────────────────────────────────────────────

  group('warm cache', () {
    test('makes zero HTTP calls when the cache is pre-populated', () async {
      cache.set(
        '$kSymbolDocCachePrefix:http:http/Client-class.html',
        Future.value('pre-populated symbol doc'),
        kSymbolDocTtl,
      );

      await buildHandler().call(
        _request({'package': 'http', 'href': 'http/Client-class.html'}),
      );

      verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
    });
  });

  // ─── Cache miss ─────────────────────────────────────────────────────────────

  group('cache miss', () {
    test('logs a debug cache-miss message', () async {
      _stubSymbolDoc(mockHttp);

      await buildHandler().call(
        _request({'package': 'http', 'href': 'http/Client-class.html'}),
      );

      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString());
      expect(debugLogs.any((m) => m.contains('cache miss')), isTrue);
    });

    test('logs an info message containing the package name on HTTP request', () async {
      _stubSymbolDoc(mockHttp);

      await buildHandler().call(
        _request({'package': 'http', 'href': 'http/Client-class.html'}),
      );

      final infoLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.info)
          .map((m) => m.$2.toString());
      expect(infoLogs.any((m) => m.contains('package=http')), isTrue);
    });
  });

  // ─── symbol_not_found ───────────────────────────────────────────────────────

  group('symbol_not_found', () {
    test('returns symbol_not_found when the href resolves to HTTP 404', () async {
      _stubSymbolDoc(mockHttp, statusCode: 404);

      final result = await buildHandler().call(
        _request({'package': 'http', 'href': 'http/Client-class.html'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['error'], equals(DomainErrors.symbolNotFound));
    });

    test('symbol_not_found payload contains a suggestion', () async {
      _stubSymbolDoc(mockHttp, statusCode: 404);

      final result = await buildHandler().call(
        _request({'package': 'http', 'href': 'http/Client-class.html'}),
      );

      expect(_errorPayload(result), contains('suggestion'));
    });

    test('symbol_not_found payload contains a message', () async {
      _stubSymbolDoc(mockHttp, statusCode: 404);

      final result = await buildHandler().call(
        _request({'package': 'http', 'href': 'http/Client-class.html'}),
      );

      expect(_errorPayload(result), contains('message'));
    });
  });

  // ─── Client failures ────────────────────────────────────────────────────────

  group('client failure', () {
    test('propagates a rate_limited error when pub.dev returns HTTP 429', () async {
      _stubSymbolDoc(mockHttp, statusCode: 429);

      final result = await buildHandler().call(
        _request({'package': 'http', 'href': 'http/Client-class.html'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['error'], equals(DomainErrors.rateLimited));
    });

    test('propagates a service_unavailable error when pub.dev returns HTTP 503', () async {
      _stubSymbolDoc(mockHttp, statusCode: 503);

      final result = await buildHandler().call(
        _request({'package': 'http', 'href': 'http/Client-class.html'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['error'], equals(DomainErrors.serviceUnavailable));
    });

    test('error payload always contains message and suggestion fields', () async {
      _stubSymbolDoc(mockHttp, statusCode: 503);

      final result = await buildHandler().call(
        _request({'package': 'http', 'href': 'http/Client-class.html'}),
      );

      expect(_errorPayload(result), contains('message'));
      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  // ─── Cache key ───────────────────────────────────────────────────────────────

  group('cache key', () {
    test('uses symbol_doc:<package>:<href> as the cache key', () async {
      _stubSymbolDoc(mockHttp);
      await buildHandler().call(
        _request({'package': 'http', 'href': 'http/Client-class.html'}),
      );

      final cachedEntry = cache.get('$kSymbolDocCachePrefix:http:http/Client-class.html');
      expect(cachedEntry, isNotNull);
    });

    test('different href values use different cache keys', () async {
      _stubSymbolDoc(mockHttp);
      _stubSymbolDoc(mockHttp, href: 'http/Client/get.html');

      final handler = buildHandler();
      await handler.call(_request({'package': 'http', 'href': 'http/Client-class.html'}));
      await handler.call(_request({'package': 'http', 'href': 'http/Client/get.html'}));

      expect(
        cache.get('$kSymbolDocCachePrefix:http:http/Client-class.html'),
        isNotNull,
      );
      expect(
        cache.get('$kSymbolDocCachePrefix:http:http/Client/get.html'),
        isNotNull,
      );
    });

    test('different packages use different cache keys', () async {
      _stubSymbolDoc(mockHttp);
      _stubSymbolDoc(mockHttp, packageName: 'dio');

      final handler = buildHandler();
      await handler.call(_request({'package': 'http', 'href': 'http/Client-class.html'}));
      await handler.call(_request({'package': 'dio', 'href': 'http/Client-class.html'}));

      expect(cache.get('$kSymbolDocCachePrefix:http:http/Client-class.html'), isNotNull);
      expect(cache.get('$kSymbolDocCachePrefix:dio:http/Client-class.html'), isNotNull);
    });
  });
}
