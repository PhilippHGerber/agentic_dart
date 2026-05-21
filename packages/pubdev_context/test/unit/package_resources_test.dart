// ignore_for_file: missing_whitespace_between_adjacent_strings for html fixtures

/// Unit tests for [PackageResourcesHandler].
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
import 'package:pubdev_context/src/resources/package_resources.dart';
import 'package:pubdev_context/src/tools/search_api_symbols.dart';
import 'package:test/test.dart';

// ─── Mocks ────────────────────────────────────────────────────────────────────

class _MockHttpClient extends Mock implements http.Client {}

// ─── Fixtures ─────────────────────────────────────────────────────────────────

String _readFixture(String name) => File('test/fixtures/$name').readAsStringSync();

http.Response _ok(String body) => http.Response(body, 200);

http.Response _status(int code) => http.Response('', code);

/// A [RetryPolicy] that never delays between attempts.
RetryPolicy get _instant => RetryPolicy(delay: (_) async {});

/// Minimal stub HTML that looks like a pub.dev documentation page with a
/// README section.
const _kReadmeHtml =
    '<html><body>'
    '<div class="desc markdown markdown-body">'
    '<h1>http</h1>'
    '<p>A composable, multi-platform HTTP library.</p>'
    '<h2>Features</h2>'
    '<p>Simple HTTP client for Dart and Flutter.</p>'
    '</div>'
    '</body></html>';

/// Minimal stub HTML that looks like a pub.dev package example page.
const _kExampleHtml =
    '<html><body>'
    '<div class="detail-tabs-content">'
    '<section class="tab-content detail-tab-example-content -active markdown-body">'
    '<p class="-monospace"><a href="https://github.com/dart-lang/http/blob/master/pkgs/http/example/main.dart">example/main.dart</a></p>'
    '<pre><code class="language-dart">main() { print(\'example\'); }</code></pre>'
    '</section>'
    '</div>'
    '</body></html>';

/// Minimal stub HTML that looks like a pub.dev changelog page.
const _kChangelogHtml =
    '<html><body>'
    '<div class="markdown-body">'
    '<h2>1.0.0</h2>'
    '<ul><li>Initial release.</li></ul>'
    '</div>'
    '</body></html>';

// ─── Stub helpers ─────────────────────────────────────────────────────────────

void _stubDocsPage(
  _MockHttpClient mock, {
  int statusCode = 200,
  String packageName = 'http',
  String body = _kReadmeHtml,
}) {
  when(
    () => mock.get(
      any(
        that: predicate<Uri>(
          (u) =>
              u.toString().contains('/documentation/$packageName/latest/') &&
              !u.toString().contains('index.json'),
        ),
      ),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer((_) async => statusCode == 200 ? _ok(body) : _status(statusCode));
}

void _stubExamplePage(
  _MockHttpClient mock, {
  int statusCode = 200,
  String packageName = 'http',
  String body = _kExampleHtml,
}) {
  when(
    () => mock.get(
      any(
        that: predicate<Uri>((u) => u.toString().contains('/packages/$packageName/example')),
      ),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer((_) async => statusCode == 200 ? _ok(body) : _status(statusCode));
}

void _stubChangelogPage(
  _MockHttpClient mock, {
  int statusCode = 200,
  String packageName = 'http',
  String body = _kChangelogHtml,
}) {
  when(
    () => mock.get(
      any(
        that: predicate<Uri>((u) => u.toString().contains('/packages/$packageName/changelog')),
      ),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer((_) async => statusCode == 200 ? _ok(body) : _status(statusCode));
}

void _stubIndexJson(
  _MockHttpClient mock, {
  int statusCode = 200,
  String packageName = 'http',
}) {
  when(
    () => mock.get(
      any(
        that: predicate<Uri>(
          (u) => u.toString().contains('/documentation/$packageName/latest/index.json'),
        ),
      ),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer(
    (_) async => statusCode == 200 ? _ok(_readFixture('index_json.json')) : _status(statusCode),
  );
}

/// Parses the dartdoc fixture symbols from disk — mirrors what [SearchApiSymbolsHandler]
/// stores in cache after a successful HTTP response.
List<DartdocSymbol> _fixtureSymbols() {
  final json = jsonDecode(_readFixture('index_json.json')) as List<Object?>;
  return json.whereType<Map<String, Object?>>().map(DartdocSymbol.fromJson).toList();
}

// ─── Request helpers ──────────────────────────────────────────────────────────

ReadResourceRequest _readmeRequest(String packageName) =>
    ReadResourceRequest(uri: 'pub://package/$packageName/readme');

ReadResourceRequest _exampleRequest(String packageName) =>
    ReadResourceRequest(uri: 'pub://package/$packageName/example');

ReadResourceRequest _apiRequest(String packageName) =>
    ReadResourceRequest(uri: 'pub://package/$packageName/api');

ReadResourceRequest _changelogRequest(String packageName) =>
    ReadResourceRequest(uri: 'pub://package/$packageName/changelog');

/// Decodes the first content item of [result] as a JSON error payload.
Map<String, Object?> _errorPayload(ReadResourceResult result) =>
    jsonDecode((result.contents.first as TextResourceContents).text) as Map<String, Object?>;

/// Returns the text from the first content item of [result].
String _text(ReadResourceResult result) => (result.contents.first as TextResourceContents).text;

/// Returns the MIME type of the first content item of [result].
String? _mimeType(ReadResourceResult result) => result.contents.first.mimeType;

// ─── Test setup ───────────────────────────────────────────────────────────────

void main() {
  late _MockHttpClient mockHttp;
  late PubDevClient client;
  late DateTime fakeNow;
  late ResponseCache<String> readmeCache;
  late ResponseCache<String> changelogCache;
  late ResponseCache<List<DartdocSymbol>> apiCache;
  final loggedMessages = <(LoggingLevel, Object)>[];

  PackageResourcesHandler buildHandler() => PackageResourcesHandler(
    client: client,
    readmeCache: readmeCache,
    changelogCache: changelogCache,
    apiIndexCache: apiCache,
    log: (level, data) => loggedMessages.add((level, data)),
  );

  setUp(() {
    mockHttp = _MockHttpClient();
    registerFallbackValue(Uri.parse('https://pub.dev'));
    client = PubDevClient(httpClient: mockHttp, retryPolicy: _instant);
    fakeNow = DateTime(2025, 5, 10);
    readmeCache = ResponseCache(clock: () => fakeNow);
    changelogCache = ResponseCache(clock: () => fakeNow);
    apiCache = ResponseCache(clock: () => fakeNow);
    loggedMessages.clear();
  });

  tearDown(() => client.close());

  // ─── Static template descriptors ─────────────────────────────────────────────

  group('static template descriptors', () {
    test('kReadmeTemplate has uri template pub://package/{name}/readme', () {
      expect(PackageResourcesHandler.kReadmeTemplate.uriTemplate, equals(kReadmeUriTemplate));
    });

    test('kReadmeTemplate has MIME type text/markdown', () {
      expect(PackageResourcesHandler.kReadmeTemplate.mimeType, equals('text/markdown'));
    });

    test('kExampleTemplate has uri template pub://package/{name}/example', () {
      expect(PackageResourcesHandler.kExampleTemplate.uriTemplate, equals(kExampleUriTemplate));
    });

    test('kExampleTemplate has MIME type text/markdown', () {
      expect(PackageResourcesHandler.kExampleTemplate.mimeType, equals('text/markdown'));
    });

    test('kApiTemplate has uri template pub://package/{name}/api', () {
      expect(PackageResourcesHandler.kApiTemplate.uriTemplate, equals(kApiUriTemplate));
    });

    test('kApiTemplate has MIME type application/json', () {
      expect(PackageResourcesHandler.kApiTemplate.mimeType, equals('application/json'));
    });

    test('kChangelogTemplate has uri template pub://package/{name}/changelog', () {
      expect(
        PackageResourcesHandler.kChangelogTemplate.uriTemplate,
        equals(kChangelogUriTemplate),
      );
    });

    test('kChangelogTemplate has MIME type text/markdown', () {
      expect(PackageResourcesHandler.kChangelogTemplate.mimeType, equals('text/markdown'));
    });
  });

  // ─── URI routing ─────────────────────────────────────────────────────────────

  group('URI routing', () {
    test('returns null for a URI that does not start with pub://package/', () async {
      final result = await buildHandler().handleReadResource(
        ReadResourceRequest(uri: 'https://pub.dev/packages/http'),
      );
      expect(result, isNull);
    });

    test('returns null for a URI with an unrecognised resource suffix', () async {
      final result = await buildHandler().handleReadResource(
        ReadResourceRequest(uri: 'pub://package/http/unknown'),
      );
      expect(result, isNull);
    });

    test('returns null when the package name segment is empty for readme', () async {
      final result = await buildHandler().handleReadResource(
        ReadResourceRequest(uri: 'pub://package//readme'),
      );
      expect(result, isNull);
    });

    test('returns null when the package name segment is empty for example', () async {
      final result = await buildHandler().handleReadResource(
        ReadResourceRequest(uri: 'pub://package//example'),
      );
      expect(result, isNull);
    });

    test('returns null when the package name segment is empty for changelog', () async {
      final result = await buildHandler().handleReadResource(
        ReadResourceRequest(uri: 'pub://package//changelog'),
      );
      expect(result, isNull);
    });

    test('returns null when the package name segment is empty for api', () async {
      final result = await buildHandler().handleReadResource(
        ReadResourceRequest(uri: 'pub://package//api'),
      );
      expect(result, isNull);
    });
  });

  // ─── README resource: cache miss ─────────────────────────────────────────────

  group('readme resource on cache miss', () {
    test('returns a non-null ReadResourceResult', () async {
      _stubDocsPage(mockHttp);
      final result = await buildHandler().handleReadResource(_readmeRequest('http'));
      expect(result, isNotNull);
    });

    test('content MIME type is text/markdown', () async {
      _stubDocsPage(mockHttp);
      final result = await buildHandler().handleReadResource(_readmeRequest('http'));
      expect(_mimeType(result!), equals('text/markdown'));
    });

    test('content text contains meaningful README content', () async {
      _stubDocsPage(mockHttp);
      final result = await buildHandler().handleReadResource(_readmeRequest('http'));
      expect(_text(result!), contains('composable'));
    });

    test('content URI matches the request URI', () async {
      _stubDocsPage(mockHttp);
      final result = await buildHandler().handleReadResource(_readmeRequest('http'));
      expect(result!.contents.first.uri, equals('pub://package/http/readme'));
    });

    test('logs an info message containing the package name', () async {
      _stubDocsPage(mockHttp);
      await buildHandler().handleReadResource(_readmeRequest('http'));
      final infoLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.info)
          .map((m) => m.$2.toString());
      expect(infoLogs.any((m) => m.contains('name=http')), isTrue);
    });

    test('logs a debug cache-miss message', () async {
      _stubDocsPage(mockHttp);
      await buildHandler().handleReadResource(_readmeRequest('http'));
      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString());
      expect(debugLogs.any((m) => m.contains('cache miss')), isTrue);
    });
  });

  // ─── Example resource: cache miss ────────────────────────────────────────────

  group('example resource on cache miss', () {
    test('returns a non-null ReadResourceResult', () async {
      _stubExamplePage(mockHttp);
      final result = await buildHandler().handleReadResource(_exampleRequest('http'));
      expect(result, isNotNull);
    });

    test('content MIME type is text/markdown', () async {
      _stubExamplePage(mockHttp);
      final result = await buildHandler().handleReadResource(_exampleRequest('http'));
      expect(_mimeType(result!), equals('text/markdown'));
    });

    test('content text contains the example code', () async {
      _stubExamplePage(mockHttp);
      final result = await buildHandler().handleReadResource(_exampleRequest('http'));
      expect(_text(result!), contains("main() { print('example'); }"));
    });

    test('content URI matches the request URI', () async {
      _stubExamplePage(mockHttp);
      final result = await buildHandler().handleReadResource(_exampleRequest('http'));
      expect(result!.contents.first.uri, equals('pub://package/http/example'));
    });

    test('logs an info message containing the package name', () async {
      _stubExamplePage(mockHttp);
      await buildHandler().handleReadResource(_exampleRequest('http'));
      final infoLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.info)
          .map((m) => m.$2.toString());
      expect(infoLogs.any((m) => m.contains('name=http')), isTrue);
    });
  });

  // ─── Example resource: cache hit ─────────────────────────────────────────────

  group('example resource on cache hit', () {
    test('makes only one HTTP call when called twice for the same package', () async {
      _stubExamplePage(mockHttp);
      final handler = buildHandler();
      await handler.handleReadResource(_exampleRequest('http'));
      fakeNow = fakeNow.add(const Duration(minutes: 30));
      await handler.handleReadResource(_exampleRequest('http'));
      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>((u) => u.toString().contains('/packages/http/example')),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('makes zero HTTP calls when the example cache is pre-populated', () async {
      readmeCache.set('example:http', Future.value('Pre-loaded example text.'), kReadmeTtl);
      await buildHandler().handleReadResource(_exampleRequest('http'));
      verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
    });

    test('returns the pre-populated cache content', () async {
      readmeCache.set('example:http', Future.value('Pre-loaded example text.'), kReadmeTtl);
      final result = await buildHandler().handleReadResource(_exampleRequest('http'));
      expect(_text(result!), equals('Pre-loaded example text.'));
    });
  });

  // ─── Example resource: empty page ────────────────────────────────────────────

  group('example resource on empty page', () {
    test('returns example_not_found in the error payload', () async {
      _stubExamplePage(
        mockHttp,
        packageName: 'missing',
        body: '<html><body><div>No example</div></body></html>',
      );
      final result = await buildHandler().handleReadResource(_exampleRequest('missing'));
      expect(_errorPayload(result!)['error'], equals(DomainErrors.exampleNotFound));
    });
  });

  // ─── README resource: cache hit ──────────────────────────────────────────────

  group('readme resource on cache hit', () {
    test('makes only one HTTP call when called twice for the same package', () async {
      _stubDocsPage(mockHttp);
      final handler = buildHandler();
      await handler.handleReadResource(_readmeRequest('http'));
      fakeNow = fakeNow.add(const Duration(minutes: 30));
      await handler.handleReadResource(_readmeRequest('http'));
      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) =>
                  u.toString().contains('/documentation/http/latest/') &&
                  !u.toString().contains('index.json'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('logs a debug cache-hit message on the second call', () async {
      _stubDocsPage(mockHttp);
      final handler = buildHandler();
      await handler.handleReadResource(_readmeRequest('http'));
      loggedMessages.clear();
      fakeNow = fakeNow.add(const Duration(minutes: 30));
      await handler.handleReadResource(_readmeRequest('http'));
      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString());
      expect(debugLogs.any((m) => m.contains('cache hit')), isTrue);
    });

    test('makes zero HTTP calls when the readme cache is pre-populated', () async {
      readmeCache.set('readme:http', Future.value('Pre-loaded README text.'), kReadmeTtl);
      await buildHandler().handleReadResource(_readmeRequest('http'));
      verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
    });

    test('returns the pre-populated cache content', () async {
      readmeCache.set('readme:http', Future.value('Pre-loaded README text.'), kReadmeTtl);
      final result = await buildHandler().handleReadResource(_readmeRequest('http'));
      expect(_text(result!), equals('Pre-loaded README text.'));
    });
  });

  // ─── README resource: 404 ────────────────────────────────────────────────────

  group('readme resource on 404', () {
    test('returns package_not_found in the error payload', () async {
      _stubDocsPage(mockHttp, statusCode: 404, packageName: 'missing');
      final result = await buildHandler().handleReadResource(_readmeRequest('missing'));
      expect(_errorPayload(result!)['error'], equals(DomainErrors.packageNotFound));
    });

    test('error payload contains a suggestion', () async {
      _stubDocsPage(mockHttp, statusCode: 404, packageName: 'missing');
      final result = await buildHandler().handleReadResource(_readmeRequest('missing'));
      expect(_errorPayload(result!), contains('suggestion'));
    });

    test('result is not null even when the package is not found', () async {
      _stubDocsPage(mockHttp, statusCode: 404, packageName: 'missing');
      final result = await buildHandler().handleReadResource(_readmeRequest('missing'));
      expect(result, isNotNull);
    });
  });

  // ─── Changelog resource: cache miss ──────────────────────────────────────────

  group('changelog resource on cache miss', () {
    test('returns a non-null ReadResourceResult', () async {
      _stubChangelogPage(mockHttp);
      final result = await buildHandler().handleReadResource(_changelogRequest('http'));
      expect(result, isNotNull);
    });

    test('content MIME type is text/markdown', () async {
      _stubChangelogPage(mockHttp);
      final result = await buildHandler().handleReadResource(_changelogRequest('http'));
      expect(_mimeType(result!), equals('text/markdown'));
    });

    test('content text contains changelog version heading', () async {
      _stubChangelogPage(mockHttp);
      final result = await buildHandler().handleReadResource(_changelogRequest('http'));
      expect(_text(result!), contains('1.0.0'));
    });

    test('content URI matches the request URI', () async {
      _stubChangelogPage(mockHttp);
      final result = await buildHandler().handleReadResource(_changelogRequest('http'));
      expect(result!.contents.first.uri, equals('pub://package/http/changelog'));
    });

    test('logs an info message containing the package name', () async {
      _stubChangelogPage(mockHttp);
      await buildHandler().handleReadResource(_changelogRequest('http'));
      final infoLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.info)
          .map((m) => m.$2.toString());
      expect(infoLogs.any((m) => m.contains('name=http')), isTrue);
    });

    test('logs a debug cache-miss message', () async {
      _stubChangelogPage(mockHttp);
      await buildHandler().handleReadResource(_changelogRequest('http'));
      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString());
      expect(debugLogs.any((m) => m.contains('cache miss')), isTrue);
    });
  });

  // ─── Changelog resource: cache hit ───────────────────────────────────────────

  group('changelog resource on cache hit', () {
    test('makes only one HTTP call when called twice for the same package', () async {
      _stubChangelogPage(mockHttp);
      final handler = buildHandler();
      await handler.handleReadResource(_changelogRequest('http'));
      fakeNow = fakeNow.add(const Duration(minutes: 30));
      await handler.handleReadResource(_changelogRequest('http'));
      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>((u) => u.toString().contains('/packages/http/changelog')),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('logs a debug cache-hit message on the second call', () async {
      _stubChangelogPage(mockHttp);
      final handler = buildHandler();
      await handler.handleReadResource(_changelogRequest('http'));
      loggedMessages.clear();
      fakeNow = fakeNow.add(const Duration(minutes: 30));
      await handler.handleReadResource(_changelogRequest('http'));
      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString());
      expect(debugLogs.any((m) => m.contains('cache hit')), isTrue);
    });

    test('makes zero HTTP calls when the changelog cache is pre-populated', () async {
      changelogCache.set(
        'changelog:http',
        Future.value('# Pre-loaded changelog'),
        kChangelogRawTtl,
      );
      await buildHandler().handleReadResource(_changelogRequest('http'));
      verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
    });

    test('returns the pre-populated cache content', () async {
      changelogCache.set(
        'changelog:http',
        Future.value('# Pre-loaded changelog'),
        kChangelogRawTtl,
      );
      final result = await buildHandler().handleReadResource(_changelogRequest('http'));
      expect(_text(result!), equals('# Pre-loaded changelog'));
    });

    test('changelog cache uses the changelog:<name> cache key prefix', () async {
      _stubChangelogPage(mockHttp);
      await buildHandler().handleReadResource(_changelogRequest('http'));
      expect(changelogCache.get('changelog:http'), isNotNull);
    });
  });

  // ─── Changelog resource: 404 ─────────────────────────────────────────────────

  group('changelog resource on 404', () {
    test('returns package_not_found in the error payload', () async {
      _stubChangelogPage(mockHttp, statusCode: 404, packageName: 'missing');
      final result = await buildHandler().handleReadResource(_changelogRequest('missing'));
      expect(_errorPayload(result!)['error'], equals(DomainErrors.packageNotFound));
    });

    test('error payload contains a suggestion', () async {
      _stubChangelogPage(mockHttp, statusCode: 404, packageName: 'missing');
      final result = await buildHandler().handleReadResource(_changelogRequest('missing'));
      expect(_errorPayload(result!), contains('suggestion'));
    });

    test('result is not null even when the package is not found', () async {
      _stubChangelogPage(mockHttp, statusCode: 404, packageName: 'missing');
      final result = await buildHandler().handleReadResource(_changelogRequest('missing'));
      expect(result, isNotNull);
    });
  });

  // ─── API resource: cache miss ─────────────────────────────────────────────────

  group('api resource on cache miss', () {
    test('returns a non-null ReadResourceResult', () async {
      _stubIndexJson(mockHttp);
      final result = await buildHandler().handleReadResource(_apiRequest('http'));
      expect(result, isNotNull);
    });

    test('content MIME type is application/json', () async {
      _stubIndexJson(mockHttp);
      final result = await buildHandler().handleReadResource(_apiRequest('http'));
      expect(_mimeType(result!), equals('application/json'));
    });

    test('content text is a valid JSON array', () async {
      _stubIndexJson(mockHttp);
      final result = await buildHandler().handleReadResource(_apiRequest('http'));
      expect(jsonDecode(_text(result!)), isA<List<Object?>>());
    });

    test('each symbol entry in the JSON array contains a name field', () async {
      _stubIndexJson(mockHttp);
      final result = await buildHandler().handleReadResource(_apiRequest('http'));
      final symbols = (jsonDecode(_text(result!)) as List<Object?>).cast<Map<String, Object?>>();
      expect(symbols.every((s) => s.containsKey('name')), isTrue);
    });

    test('each symbol entry contains a type field', () async {
      _stubIndexJson(mockHttp);
      final result = await buildHandler().handleReadResource(_apiRequest('http'));
      final symbols = (jsonDecode(_text(result!)) as List<Object?>).cast<Map<String, Object?>>();
      expect(symbols.every((s) => s.containsKey('type')), isTrue);
    });

    test('content URI matches the request URI', () async {
      _stubIndexJson(mockHttp);
      final result = await buildHandler().handleReadResource(_apiRequest('http'));
      expect(result!.contents.first.uri, equals('pub://package/http/api'));
    });

    test('logs a debug cache-miss message', () async {
      _stubIndexJson(mockHttp);
      await buildHandler().handleReadResource(_apiRequest('http'));
      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString());
      expect(debugLogs.any((m) => m.contains('cache miss')), isTrue);
    });
  });

  // ─── API resource: cache hit ──────────────────────────────────────────────────

  group('api resource on cache hit', () {
    test('makes only one HTTP call when called twice for the same package', () async {
      _stubIndexJson(mockHttp);
      final handler = buildHandler();
      await handler.handleReadResource(_apiRequest('http'));
      fakeNow = fakeNow.add(const Duration(minutes: 30));
      await handler.handleReadResource(_apiRequest('http'));
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

    test('logs a debug cache-hit message on the second call', () async {
      _stubIndexJson(mockHttp);
      final handler = buildHandler();
      await handler.handleReadResource(_apiRequest('http'));
      loggedMessages.clear();
      fakeNow = fakeNow.add(const Duration(minutes: 30));
      await handler.handleReadResource(_apiRequest('http'));
      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString());
      expect(debugLogs.any((m) => m.contains('cache hit')), isTrue);
    });

    test('makes zero HTTP calls when the api index cache is pre-populated', () async {
      apiCache.set('api_index:http', Future.value(_fixtureSymbols()), kApiDocsTtl);
      await buildHandler().handleReadResource(_apiRequest('http'));
      verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
    });
  });

  // ─── API resource: 404 ───────────────────────────────────────────────────────

  group('api resource on 404', () {
    test('returns package_not_found in the error payload', () async {
      _stubIndexJson(mockHttp, statusCode: 404, packageName: 'missing');
      final result = await buildHandler().handleReadResource(_apiRequest('missing'));
      expect(_errorPayload(result!)['error'], equals(DomainErrors.packageNotFound));
    });

    test('error payload contains a suggestion', () async {
      _stubIndexJson(mockHttp, statusCode: 404, packageName: 'missing');
      final result = await buildHandler().handleReadResource(_apiRequest('missing'));
      expect(_errorPayload(result!), contains('suggestion'));
    });
  });

  // ─── Shared cache key ─────────────────────────────────────────────────────────

  group('shared cache key between PackageResourcesHandler and SearchApiSymbolsHandler', () {
    test(
      'api resource makes zero HTTP calls when SearchApiSymbolsHandler has warmed the cache',
      () async {
        // Warm the cache via SearchApiSymbolsHandler (issue 09).
        _stubIndexJson(mockHttp);
        final symbolsHandler = SearchApiSymbolsHandler(
          client: client,
          cache: apiCache,
          log: (_, _) {},
        );
        await symbolsHandler.call(
          CallToolRequest(
            name: 'search_api_symbols',
            arguments: {'package': 'http', 'query': ''},
          ),
        );

        // Now read the API resource — should use the warm cache.
        await buildHandler().handleReadResource(_apiRequest('http'));

        // Only one HTTP request was made in total (from SearchApiSymbolsHandler).
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
      },
    );

    test(
      'SearchApiSymbolsHandler makes zero HTTP calls when PackageResourcesHandler has warmed the cache',
      () async {
        // Warm the cache via PackageResourcesHandler.
        _stubIndexJson(mockHttp);
        await buildHandler().handleReadResource(_apiRequest('http'));

        // Now call SearchApiSymbolsHandler — should use the warm cache.
        final symbolsHandler = SearchApiSymbolsHandler(
          client: client,
          cache: apiCache,
          log: (_, _) {},
        );
        await symbolsHandler.call(
          CallToolRequest(
            name: 'search_api_symbols',
            arguments: {'package': 'http', 'query': 'client'},
          ),
        );

        // Only one HTTP request was made in total (from PackageResourcesHandler).
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
      },
    );

    test('api resource uses the api_index:<name> cache key prefix', () async {
      _stubIndexJson(mockHttp);
      await buildHandler().handleReadResource(_apiRequest('http'));
      expect(apiCache.get('api_index:http'), isNotNull);
    });

    test('readme resource uses the readme:<name> cache key prefix', () async {
      _stubDocsPage(mockHttp);
      await buildHandler().handleReadResource(_readmeRequest('http'));
      expect(readmeCache.get('readme:http'), isNotNull);
    });
  });

  // ─── Client error propagation ─────────────────────────────────────────────────

  group('client error propagation for readme resource', () {
    test('returns a rate_limited error payload when pub.dev returns HTTP 429', () async {
      _stubDocsPage(mockHttp, statusCode: 429);
      final result = await buildHandler().handleReadResource(_readmeRequest('http'));
      expect(_errorPayload(result!)['error'], equals(DomainErrors.rateLimited));
    });

    test('returns a service_unavailable error payload on HTTP 503', () async {
      _stubDocsPage(mockHttp, statusCode: 503);
      final result = await buildHandler().handleReadResource(_readmeRequest('http'));
      expect(_errorPayload(result!)['error'], equals(DomainErrors.serviceUnavailable));
    });
  });

  group('client error propagation for example resource', () {
    test('returns a rate_limited error payload when pub.dev returns HTTP 429', () async {
      _stubExamplePage(mockHttp, statusCode: 429);
      final result = await buildHandler().handleReadResource(_exampleRequest('http'));
      expect(_errorPayload(result!)['error'], equals(DomainErrors.rateLimited));
    });

    test('returns a service_unavailable error payload on HTTP 503', () async {
      _stubExamplePage(mockHttp, statusCode: 503);
      final result = await buildHandler().handleReadResource(_exampleRequest('http'));
      expect(_errorPayload(result!)['error'], equals(DomainErrors.serviceUnavailable));
    });

    test('returns package_not_found in the error payload on 404', () async {
      _stubExamplePage(mockHttp, statusCode: 404, packageName: 'missing');
      final result = await buildHandler().handleReadResource(_exampleRequest('missing'));
      expect(_errorPayload(result!)['error'], equals(DomainErrors.packageNotFound));
    });
  });

  group('client error propagation for changelog resource', () {
    test('returns a rate_limited error payload when pub.dev returns HTTP 429', () async {
      _stubChangelogPage(mockHttp, statusCode: 429);
      final result = await buildHandler().handleReadResource(_changelogRequest('http'));
      expect(_errorPayload(result!)['error'], equals(DomainErrors.rateLimited));
    });

    test('returns a service_unavailable error payload on HTTP 503', () async {
      _stubChangelogPage(mockHttp, statusCode: 503);
      final result = await buildHandler().handleReadResource(_changelogRequest('http'));
      expect(_errorPayload(result!)['error'], equals(DomainErrors.serviceUnavailable));
    });

    test('returns package_not_found in the error payload on 404', () async {
      _stubChangelogPage(mockHttp, statusCode: 404, packageName: 'missing');
      final result = await buildHandler().handleReadResource(_changelogRequest('missing'));
      expect(_errorPayload(result!)['error'], equals(DomainErrors.packageNotFound));
    });
  });

  group('client error propagation for api resource', () {
    test('returns a rate_limited error payload when pub.dev returns HTTP 429', () async {
      _stubIndexJson(mockHttp, statusCode: 429);
      final result = await buildHandler().handleReadResource(_apiRequest('http'));
      expect(_errorPayload(result!)['error'], equals(DomainErrors.rateLimited));
    });

    test('returns a service_unavailable error payload on HTTP 503', () async {
      _stubIndexJson(mockHttp, statusCode: 503);
      final result = await buildHandler().handleReadResource(_apiRequest('http'));
      expect(_errorPayload(result!)['error'], equals(DomainErrors.serviceUnavailable));
    });
  });

  // ─── Completions ─────────────────────────────────────────────────────────────
  //
  // CompletionsSupport for {name} lives in the server (PubMcpServer.handleComplete),
  // but the underlying search-cache scan is tested here against a bare ResponseCache.

  group('ResponseCache.entries for completions', () {
    late ResponseCache<List<PackageSummary>> searchCache;

    setUp(() {
      searchCache = ResponseCache(clock: () => fakeNow);
    });

    test('returns an empty map when the cache has no entries', () {
      expect(searchCache.entries, isEmpty);
    });

    test('includes a non-expired entry', () {
      searchCache.set('search:http:5:1::relevance:', Future.value([]), kSearchResultsTtl);
      expect(searchCache.entries, hasLength(1));
    });

    test('excludes an expired entry', () {
      searchCache.set('search:http:5:1::relevance:', Future.value([]), kSearchResultsTtl);
      fakeNow = fakeNow.add(kSearchResultsTtl + const Duration(seconds: 1));
      expect(searchCache.entries, isEmpty);
    });

    test('package names can be extracted from all cached search entries', () async {
      const httpSummary = PackageSummary(
        name: 'http',
        version: '1.6.0',
        description: 'HTTP client',
        likes: 0,
        pubPoints: 0,
        popularity: 0,
        verified: false,
        sdks: [],
        platforms: [],
        topics: [],
        isFlutterFavorite: false,
        daysSinceUpdate: 0,
        activeMaintenance: true,
      );
      final dioSummary = httpSummary.copyWith(name: 'dio');
      searchCache
        ..set(
          'search:http:5:1::relevance:',
          Future.value([httpSummary]),
          kSearchResultsTtl,
        )
        ..set(
          'search:dio:5:1::relevance:',
          Future.value([dioSummary]),
          kSearchResultsTtl,
        );

      final names = <String>{};
      for (final future in searchCache.entries.values) {
        final results = await future;
        names.addAll(results.map((s) => s.name));
      }

      expect(names, containsAll(['http', 'dio']));
    });

    test('filtering by partial prefix returns only matching package names', () async {
      const httpSummary = PackageSummary(
        name: 'http',
        version: '1.6.0',
        description: 'HTTP client',
        likes: 0,
        pubPoints: 0,
        popularity: 0,
        verified: false,
        sdks: [],
        platforms: [],
        topics: [],
        isFlutterFavorite: false,
        daysSinceUpdate: 0,
        activeMaintenance: true,
      );
      final dioSummary = httpSummary.copyWith(name: 'dio');
      final httpParserSummary = httpSummary.copyWith(name: 'http_parser');
      searchCache.set(
        'search:http:5:1::relevance:',
        Future.value([httpSummary, dioSummary, httpParserSummary]),
        kSearchResultsTtl,
      );

      const partial = 'http';
      final names = <String>{};
      for (final future in searchCache.entries.values) {
        final results = await future;
        names.addAll(results.map((s) => s.name));
      }
      final matches = names.where((n) => n.toLowerCase().startsWith(partial.toLowerCase())).toList()
        ..sort();

      expect(matches, containsAll(['http', 'http_parser']));
      expect(matches, isNot(contains('dio')));
    });
  });
}
