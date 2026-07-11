// ignore_for_file: missing_whitespace_between_adjacent_strings for html fixtures

/// Unit tests for [PackageResourcesHandler].
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dart_mcp/server.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:pubdev_context/src/cache/cache_registry.dart';
import 'package:pubdev_context/src/cache/memory_cache.dart';
import 'package:pubdev_context/src/data/domain_error.dart';
import 'package:pubdev_context/src/data/models.dart';
import 'package:pubdev_context/src/data/pub_client.dart';
import 'package:pubdev_context/src/resources/package_resources.dart';
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
    (_) async => statusCode == 200 ? _ok(_readFixture('index_json.json')) : _status(statusCode),
  );
}

/// Stubs the package-info endpoint used by [PubDevClient.resolveLatestStable].
///
/// When [statusCode] is not 200 the endpoint returns that status so version
/// resolution fails with `package_not_found`. Otherwise it returns a minimal
/// JSON body that makes [PubDevClient.resolveLatestStable] return [version].
void _stubPackageInfo(
  _MockHttpClient mock, {
  String packageName = 'http',
  String version = '1.6.0',
  int statusCode = 200,
}) {
  if (statusCode != 200) {
    when(
      () => mock.get(
        any(
          that: predicate<Uri>(
            (u) =>
                u.toString().contains('/api/packages/$packageName') &&
                !u.toString().contains('/score') &&
                !u.toString().contains('/versions/') &&
                !u.toString().contains('/archive'),
          ),
        ),
        headers: any(named: 'headers'),
      ),
    ).thenAnswer((_) async => _status(statusCode));
    return;
  }
  final body = jsonEncode({
    'versions': [
      {'version': version},
    ],
    'latest': {'version': version},
  });
  when(
    () => mock.get(
      any(
        that: predicate<Uri>(
          (u) =>
              u.toString().contains('/api/packages/$packageName') &&
              !u.toString().contains('/score') &&
              !u.toString().contains('/versions/') &&
              !u.toString().contains('/archive'),
        ),
      ),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer((_) async => _ok(body));
}

Uint8List _buildTarGz(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.string(entry.key, entry.value));
  }
  final tar = TarEncoder().encodeBytes(archive);
  return const GZipEncoder().encodeBytes(tar);
}

/// Stubs the version-tarball endpoint (`send`, not `get`) with a gzip archive
/// built from [files]. A non-200 [statusCode] returns an empty body.
void _stubTarball(
  _MockHttpClient mock,
  Map<String, String> files, {
  String packageName = 'http',
  String version = '1.6.0',
  int statusCode = 200,
}) {
  when(
    () => mock.send(
      any(
        that: predicate<http.BaseRequest>(
          (r) => r.url.toString().contains(
            '/api/packages/$packageName/versions/$version/archive.tar.gz',
          ),
        ),
      ),
    ),
  ).thenAnswer(
    (_) async => statusCode == 200
        ? http.StreamedResponse(Stream.value(_buildTarGz(files)), 200)
        : http.StreamedResponse(const Stream.empty(), statusCode),
  );
}

/// A minimal pubspec.yaml fixture used by the pubspec-resource tests.
const _kPubspecYaml =
    'name: http\n'
    'version: 1.6.0\n'
    'description: A composable, multi-platform HTTP library.\n'
    'environment:\n'
    "  sdk: '>=3.0.0 <4.0.0'\n";

// ─── Request helpers ──────────────────────────────────────────────────────────

ReadResourceRequest _readmeRequest(String packageName, {String version = '1.6.0'}) =>
    ReadResourceRequest(uri: 'pub://package/$packageName@$version/readme');

ReadResourceRequest _exampleRequest(String packageName, {String version = '1.6.0'}) =>
    ReadResourceRequest(uri: 'pub://package/$packageName@$version/example');

ReadResourceRequest _apiRequest(String packageName, {String version = 'latest'}) =>
    ReadResourceRequest(uri: 'pub://package/$packageName@$version/api');

ReadResourceRequest _changelogRequest(String packageName, {String version = '1.6.0'}) =>
    ReadResourceRequest(uri: 'pub://package/$packageName@$version/changelog');

ReadResourceRequest _pubspecRequest(String packageName, {String version = '1.6.0'}) =>
    ReadResourceRequest(uri: 'pub://package/$packageName@$version/pubspec');

/// Decodes the first content item of [result] as a JSON error payload.
Map<String, Object?> _errorPayload(ReadResourceResult result) {
  final outer = jsonDecode((result.contents.first as TextResourceContents).text) as Map<String, Object?>;
  final inner = outer['error'];
  if (inner is! Map<String, Object?>) throw StateError('No nested error object');
  return inner;
}

/// Returns the text from the first content item of [result].
String _text(ReadResourceResult result) => (result.contents.first as TextResourceContents).text;

/// The `[Resolved Version: x.y.z]` header line prefixed to every success body.
String _header(ReadResourceResult result) => _text(result).split('\n').first;

/// The response body with the leading resolved-version header line removed.
String _body(ReadResourceResult result) {
  final text = _text(result);
  final nl = text.indexOf('\n');
  return nl < 0 ? '' : text.substring(nl + 1);
}

/// Returns the MIME type of the first content item of [result].
String? _mimeType(ReadResourceResult result) => result.contents.first.mimeType;

// ─── Test setup ───────────────────────────────────────────────────────────────

void main() {
  late _MockHttpClient mockHttp;
  late PubDevClient client;
  late DateTime fakeNow;
  late CacheRegistry registry;

  PackageResourcesHandler buildHandler() => PackageResourcesHandler(
    client: client,
    readme: registry.readme,
    apiIndex: registry.apiIndex,
    sourceFiles: registry.sourceFiles,
  );

  setUp(() {
    mockHttp = _MockHttpClient();
    registerFallbackValue(Uri.parse('https://pub.dev'));
    registerFallbackValue(http.Request('GET', Uri.parse('https://pub.dev')));
    client = PubDevClient(httpClient: mockHttp, retryPolicy: _instant);
    fakeNow = DateTime(2025, 5, 10);
    registry = CacheRegistry(client: client, clock: () => fakeNow);
  });

  tearDown(() => client.close());

  // ─── Static template descriptors ─────────────────────────────────────────────

  group('static template descriptors', () {
    test('kReadmeTemplate uri template carries the {name}@{version} segment', () {
      expect(
        PackageResourcesHandler.kReadmeTemplate.uriTemplate,
        equals('pub://package/{name}@{version}/readme'),
      );
      expect(PackageResourcesHandler.kReadmeTemplate.uriTemplate, equals(kReadmeUriTemplate));
    });

    test('kReadmeTemplate has MIME type text/markdown', () {
      expect(PackageResourcesHandler.kReadmeTemplate.mimeType, equals('text/markdown'));
    });

    test('kExampleTemplate uri template carries the {name}@{version} segment', () {
      expect(
        PackageResourcesHandler.kExampleTemplate.uriTemplate,
        equals('pub://package/{name}@{version}/example'),
      );
      expect(PackageResourcesHandler.kExampleTemplate.uriTemplate, equals(kExampleUriTemplate));
    });

    test('kExampleTemplate has MIME type text/markdown', () {
      expect(PackageResourcesHandler.kExampleTemplate.mimeType, equals('text/markdown'));
    });

    test('kApiTemplate uri template carries the {name}@{version} segment', () {
      expect(
        PackageResourcesHandler.kApiTemplate.uriTemplate,
        equals('pub://package/{name}@{version}/api'),
      );
      expect(PackageResourcesHandler.kApiTemplate.uriTemplate, equals(kApiUriTemplate));
    });

    test('kApiTemplate has MIME type application/json', () {
      expect(PackageResourcesHandler.kApiTemplate.mimeType, equals('application/json'));
    });

    test('kChangelogTemplate uri template carries the {name}@{version} segment', () {
      expect(
        PackageResourcesHandler.kChangelogTemplate.uriTemplate,
        equals('pub://package/{name}@{version}/changelog'),
      );
      expect(
        PackageResourcesHandler.kChangelogTemplate.uriTemplate,
        equals(kChangelogUriTemplate),
      );
    });

    test('kChangelogTemplate has MIME type text/markdown', () {
      expect(PackageResourcesHandler.kChangelogTemplate.mimeType, equals('text/markdown'));
    });

    test('kPubspecTemplate uri template carries the {name}@{version} segment', () {
      expect(
        PackageResourcesHandler.kPubspecTemplate.uriTemplate,
        equals('pub://package/{name}@{version}/pubspec'),
      );
      expect(PackageResourcesHandler.kPubspecTemplate.uriTemplate, equals(kPubspecUriTemplate));
    });

    test('kPubspecTemplate has MIME type text/plain', () {
      expect(PackageResourcesHandler.kPubspecTemplate.mimeType, equals('text/plain'));
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

    test('returns null when the package name segment is empty for pubspec', () async {
      final result = await buildHandler().handleReadResource(
        ReadResourceRequest(uri: 'pub://package//pubspec'),
      );
      expect(result, isNull);
    });

    test('returns null for a versionless pubspec URI', () async {
      final result = await buildHandler().handleReadResource(
        ReadResourceRequest(uri: 'pub://package/http/pubspec'),
      );
      expect(result, isNull);
    });

    test('returns null for a versionless URI', () async {
      final result = await buildHandler().handleReadResource(
        ReadResourceRequest(uri: 'pub://package/http/readme'),
      );
      expect(result, isNull);
    });

    test('returns null when the version segment is empty', () async {
      final result = await buildHandler().handleReadResource(
        ReadResourceRequest(uri: 'pub://package/http@/readme'),
      );
      expect(result, isNull);
    });

    test('returns null when the name segment is empty but a version is present', () async {
      final result = await buildHandler().handleReadResource(
        ReadResourceRequest(uri: 'pub://package/@1.0.0/readme'),
      );
      expect(result, isNull);
    });
  });

  // ─── Resolved-version header ─────────────────────────────────────────────────
  //
  // Every successful package resource body is prefixed with a
  // `[Resolved Version: x.y.z]` grounding header. An explicit version is echoed
  // verbatim; `latest` resolves to the Latest Stable Version at request time.

  group('resolved-version header', () {
    test('readme with an explicit version echoes it in the header', () async {
      _stubDocsPage(mockHttp);
      final result = await buildHandler().handleReadResource(
        _readmeRequest('http', version: '1.2.0'),
      );
      expect(_header(result!), equals('[Resolved Version: 1.2.0]'));
    });

    test('readme with an explicit version does not call resolveLatestStable', () async {
      _stubDocsPage(mockHttp);
      await buildHandler().handleReadResource(_readmeRequest('http', version: '1.2.0'));
      verifyNever(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) =>
                  u.toString().contains('/api/packages/http') &&
                  !u.toString().contains('/documentation/'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      );
    });

    test('readme header keeps the actual README body below it', () async {
      _stubDocsPage(mockHttp);
      final result = await buildHandler().handleReadResource(
        _readmeRequest('http', version: '1.2.0'),
      );
      expect(_body(result!), contains('composable'));
    });

    test('readme with version=latest resolves to the Latest Stable Version', () async {
      _stubPackageInfo(mockHttp);
      _stubDocsPage(mockHttp);
      final result = await buildHandler().handleReadResource(
        _readmeRequest('http', version: 'latest'),
      );
      expect(_header(result!), equals('[Resolved Version: 1.6.0]'));
    });

    test('readme with version=latest propagates package_not_found on resolve 404', () async {
      _stubPackageInfo(mockHttp, packageName: 'missing', statusCode: 404);
      final result = await buildHandler().handleReadResource(
        _readmeRequest('missing', version: 'latest'),
      );
      expect(_errorPayload(result!)['code'], equals(DomainErrors.packageNotFound));
    });

    test('changelog with an explicit version echoes it in the header', () async {
      _stubChangelogPage(mockHttp);
      final result = await buildHandler().handleReadResource(
        _changelogRequest('http', version: '2.5.1'),
      );
      expect(_header(result!), equals('[Resolved Version: 2.5.1]'));
    });

    test('example with an explicit version echoes it in the header', () async {
      _stubExamplePage(mockHttp);
      final result = await buildHandler().handleReadResource(
        _exampleRequest('http', version: '0.9.0'),
      );
      expect(_header(result!), equals('[Resolved Version: 0.9.0]'));
    });

    test('api with version=latest resolves and grounds the header', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);
      final result = await buildHandler().handleReadResource(_apiRequest('http'));
      expect(_header(result!), equals('[Resolved Version: 1.6.0]'));
      // The JSON payload survives below the header line.
      expect(jsonDecode(_body(result)), isA<List<Object?>>());
    });

    test('api with an explicit version fetches that version and echoes it', () async {
      _stubIndexJson(mockHttp, version: '1.2.0');
      final result = await buildHandler().handleReadResource(
        _apiRequest('http', version: '1.2.0'),
      );
      expect(_header(result!), equals('[Resolved Version: 1.2.0]'));
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

    test('api with an explicit version does not call resolveLatestStable', () async {
      _stubIndexJson(mockHttp, version: '1.2.0');
      await buildHandler().handleReadResource(_apiRequest('http', version: '1.2.0'));
      verifyNever(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().endsWith('/api/packages/http'))),
          headers: any(named: 'headers'),
        ),
      );
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
      expect(result!.contents.first.uri, equals('pub://package/http@1.6.0/readme'));
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
      expect(result!.contents.first.uri, equals('pub://package/http@1.6.0/example'));
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

    test('makes no additional HTTP call when the example cache is already warm', () async {
      _stubExamplePage(mockHttp);
      await registry.readme.resolve((name: 'http', kind: ReadmeKind.example));

      await buildHandler().handleReadResource(_exampleRequest('http'));

      // Only the warm-up fetch above ran — the handler call itself was a hit.
      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>((u) => u.toString().contains('/packages/http/example')),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('returns the pre-warmed cache content', () async {
      _stubExamplePage(mockHttp);
      await registry.readme.resolve((name: 'http', kind: ReadmeKind.example));

      final result = await buildHandler().handleReadResource(_exampleRequest('http'));
      expect(_body(result!), contains("main() { print('example'); }"));
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
      expect(_errorPayload(result!)['code'], equals(DomainErrors.exampleNotFound));
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

    test('makes no additional HTTP call when the readme cache is already warm', () async {
      _stubDocsPage(mockHttp);
      await registry.readme.resolve((name: 'http', kind: ReadmeKind.readme));

      await buildHandler().handleReadResource(_readmeRequest('http'));

      // Only the warm-up fetch above ran — the handler call itself was a hit.
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

    test('returns the pre-warmed cache content', () async {
      _stubDocsPage(mockHttp);
      await registry.readme.resolve((name: 'http', kind: ReadmeKind.readme));

      final result = await buildHandler().handleReadResource(_readmeRequest('http'));
      expect(_body(result!), contains('composable'));
    });
  });

  // ─── README resource: 404 ────────────────────────────────────────────────────

  group('readme resource on 404', () {
    test('returns package_not_found in the error payload', () async {
      _stubDocsPage(mockHttp, statusCode: 404, packageName: 'missing');
      final result = await buildHandler().handleReadResource(_readmeRequest('missing'));
      expect(_errorPayload(result!)['code'], equals(DomainErrors.packageNotFound));
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
      expect(result!.contents.first.uri, equals('pub://package/http@1.6.0/changelog'));
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

    test('makes no additional HTTP call when the changelog cache is already warm', () async {
      _stubChangelogPage(mockHttp);
      await registry.readme.resolve((name: 'http', kind: ReadmeKind.changelog));

      await buildHandler().handleReadResource(_changelogRequest('http'));

      // Only the warm-up fetch above ran — the handler call itself was a hit.
      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>((u) => u.toString().contains('/packages/http/changelog')),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('returns the pre-warmed cache content', () async {
      _stubChangelogPage(mockHttp);
      await registry.readme.resolve((name: 'http', kind: ReadmeKind.changelog));

      final result = await buildHandler().handleReadResource(_changelogRequest('http'));
      expect(_body(result!), contains('1.0.0'));
    });
  });

  // ─── Changelog resource: 404 ─────────────────────────────────────────────────

  group('changelog resource on 404', () {
    test('returns package_not_found in the error payload', () async {
      _stubChangelogPage(mockHttp, statusCode: 404, packageName: 'missing');
      final result = await buildHandler().handleReadResource(_changelogRequest('missing'));
      expect(_errorPayload(result!)['code'], equals(DomainErrors.packageNotFound));
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
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);
      final result = await buildHandler().handleReadResource(_apiRequest('http'));
      expect(result, isNotNull);
    });

    test('content MIME type is application/json', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);
      final result = await buildHandler().handleReadResource(_apiRequest('http'));
      expect(_mimeType(result!), equals('application/json'));
    });

    test('content text is a valid JSON array', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);
      final result = await buildHandler().handleReadResource(_apiRequest('http'));
      expect(jsonDecode(_body(result!)), isA<List<Object?>>());
    });

    test('each symbol entry in the JSON array contains a name field', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);
      final result = await buildHandler().handleReadResource(_apiRequest('http'));
      final symbols = (jsonDecode(_body(result!)) as List<Object?>).cast<Map<String, Object?>>();
      expect(symbols.every((s) => s.containsKey('name')), isTrue);
    });

    test('each symbol entry contains a type field', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);
      final result = await buildHandler().handleReadResource(_apiRequest('http'));
      final symbols = (jsonDecode(_body(result!)) as List<Object?>).cast<Map<String, Object?>>();
      expect(symbols.every((s) => s.containsKey('type')), isTrue);
    });

    test('content URI matches the request URI', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);
      final result = await buildHandler().handleReadResource(_apiRequest('http'));
      expect(result!.contents.first.uri, equals('pub://package/http@latest/api'));
    });

  });

  // ─── API resource: cache hit ──────────────────────────────────────────────────

  group('api resource on cache hit', () {
    test('makes only one HTTP call when called twice for the same package', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);
      final handler = buildHandler();
      await handler.handleReadResource(_apiRequest('http'));
      fakeNow = fakeNow.add(const Duration(minutes: 30));
      await handler.handleReadResource(_apiRequest('http'));
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

    test('makes no index HTTP call when the api index cache is already warm', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);
      await registry.apiIndex.resolve((name: 'http', version: '1.6.0'));

      await buildHandler().handleReadResource(_apiRequest('http'));

      // Only the warm-up fetch above ran — the handler call itself was a hit.
      verify(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('/index.json'))),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });
  });

  // ─── API resource: 404 ───────────────────────────────────────────────────────

  group('api resource on 404', () {
    test('returns package_not_found in the error payload', () async {
      _stubPackageInfo(mockHttp, packageName: 'missing', statusCode: 404);
      final result = await buildHandler().handleReadResource(_apiRequest('missing'));
      expect(_errorPayload(result!)['code'], equals(DomainErrors.packageNotFound));
    });

    test('error payload contains a suggestion', () async {
      _stubPackageInfo(mockHttp, packageName: 'missing', statusCode: 404);
      final result = await buildHandler().handleReadResource(_apiRequest('missing'));
      expect(_errorPayload(result!), contains('suggestion'));
    });
  });

  // ─── API resource: resolve failure (P1.15) ───────────────────────────────────
  //
  // The api resource resolves the latest stable version before touching the
  // index. A failed resolution (404) must propagate as package_not_found and
  // must short-circuit — the index endpoint is never fetched.

  group('api resource — resolve failure short-circuits the index fetch (P1.15)', () {
    test('propagates package_not_found when version resolution returns 404', () async {
      _stubPackageInfo(mockHttp, packageName: 'missing', statusCode: 404);
      _stubIndexJson(mockHttp, packageName: 'missing');
      final result = await buildHandler().handleReadResource(_apiRequest('missing'));
      expect(_errorPayload(result!)['code'], equals(DomainErrors.packageNotFound));
    });

    test('does not fetch the index when version resolution fails', () async {
      _stubPackageInfo(mockHttp, packageName: 'missing', statusCode: 404);
      _stubIndexJson(mockHttp, packageName: 'missing');
      await buildHandler().handleReadResource(_apiRequest('missing'));
      verifyNever(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('/index.json'))),
          headers: any(named: 'headers'),
        ),
      );
    });
  });

  // ─── API resource: cache poisoning on transient failure (P0.4) ──────────────
  //
  // A single transient index failure (429/503/network) must not be stored as an
  // empty index for the full TTL. A second read must retry and succeed.

  group('api resource — transient failure must not poison the cache (P0.4)', () {
    test('a transient index 503 is not cached — a second read retries and succeeds', () async {
      _stubPackageInfo(mockHttp);
      // The index endpoint fails with 503 during the first read (the client
      // exhausts its retries), then recovers for the second read.
      var indexHealthy = false;
      when(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/1.6.0/index.json'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer(
        (_) async => indexHealthy ? _ok(_readFixture('index_json.json')) : _status(503),
      );
      final handler = buildHandler();

      // First read surfaces the transient failure.
      final first = await handler.handleReadResource(_apiRequest('http'));
      expect(_errorPayload(first!)['code'], equals(DomainErrors.serviceUnavailable));

      // The failure must NOT have been cached — the index cache stays cold.
      expect(await registry.apiIndex.peek((name: 'http', version: '1.6.0')), isNull);

      // The outage clears; the second read retries the fetch and succeeds.
      indexHealthy = true;
      final second = await handler.handleReadResource(_apiRequest('http'));
      expect(_mimeType(second!), equals('application/json'));
      expect(jsonDecode(_body(second)), isA<List<Object?>>());
    });

    test('a transient index 429 is not cached — a second read retries and succeeds', () async {
      _stubPackageInfo(mockHttp);
      // The index endpoint is rate-limited (429) during the first read, then
      // recovers for the second read.
      var indexHealthy = false;
      when(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/1.6.0/index.json'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer(
        (_) async => indexHealthy ? _ok(_readFixture('index_json.json')) : _status(429),
      );
      final handler = buildHandler();

      // First read surfaces the rate-limit failure.
      final first = await handler.handleReadResource(_apiRequest('http'));
      expect(_errorPayload(first!)['code'], equals(DomainErrors.rateLimited));

      // The failure must NOT have been cached — the index cache stays cold.
      expect(await registry.apiIndex.peek((name: 'http', version: '1.6.0')), isNull);

      // The rate limit clears; the second read retries the fetch and succeeds.
      indexHealthy = true;
      final second = await handler.handleReadResource(_apiRequest('http'));
      expect(_mimeType(second!), equals('application/json'));
      expect(jsonDecode(_body(second)), isA<List<Object?>>());
    });
  });

  // ─── Pubspec resource: cache miss ────────────────────────────────────────────

  group('pubspec resource on cache miss', () {
    test('returns a non-null ReadResourceResult', () async {
      _stubTarball(mockHttp, {kPubspecFileName: _kPubspecYaml});
      final result = await buildHandler().handleReadResource(_pubspecRequest('http'));
      expect(result, isNotNull);
    });

    test('content MIME type is text/plain', () async {
      _stubTarball(mockHttp, {kPubspecFileName: _kPubspecYaml});
      final result = await buildHandler().handleReadResource(_pubspecRequest('http'));
      expect(_mimeType(result!), equals('text/plain'));
    });

    test('content body is the verbatim pubspec.yaml', () async {
      _stubTarball(mockHttp, {kPubspecFileName: _kPubspecYaml});
      final result = await buildHandler().handleReadResource(_pubspecRequest('http'));
      expect(_body(result!), equals(_kPubspecYaml));
    });

    test('content URI matches the request URI', () async {
      _stubTarball(mockHttp, {kPubspecFileName: _kPubspecYaml});
      final result = await buildHandler().handleReadResource(_pubspecRequest('http'));
      expect(result!.contents.first.uri, equals('pub://package/http@1.6.0/pubspec'));
    });
  });

  // ─── Pubspec resource: resolved-version header ───────────────────────────────

  group('pubspec resource resolved-version header', () {
    test('explicit version echoes it in the header', () async {
      _stubTarball(mockHttp, {kPubspecFileName: _kPubspecYaml}, version: '1.2.0');
      final result = await buildHandler().handleReadResource(
        _pubspecRequest('http', version: '1.2.0'),
      );
      expect(_header(result!), equals('[Resolved Version: 1.2.0]'));
    });

    test('explicit version does not call resolveLatestStable', () async {
      _stubTarball(mockHttp, {kPubspecFileName: _kPubspecYaml}, version: '1.2.0');
      await buildHandler().handleReadResource(_pubspecRequest('http', version: '1.2.0'));
      verifyNever(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().endsWith('/api/packages/http'))),
          headers: any(named: 'headers'),
        ),
      );
    });

    test('version=latest resolves to the Latest Stable Version', () async {
      _stubPackageInfo(mockHttp);
      _stubTarball(mockHttp, {kPubspecFileName: _kPubspecYaml});
      final result = await buildHandler().handleReadResource(
        _pubspecRequest('http', version: 'latest'),
      );
      expect(_header(result!), equals('[Resolved Version: 1.6.0]'));
    });
  });

  // ─── Pubspec resource: cache hit / shared source cache ───────────────────────

  group('pubspec resource on cache hit', () {
    test('makes only one tarball download when called twice for the same version', () async {
      _stubTarball(mockHttp, {kPubspecFileName: _kPubspecYaml});
      final handler = buildHandler();
      await handler.handleReadResource(_pubspecRequest('http'));
      fakeNow = fakeNow.add(const Duration(minutes: 30));
      await handler.handleReadResource(_pubspecRequest('http'));
      verify(() => mockHttp.send(any())).called(1);
    });

    test('makes no additional tarball download when the source cache is already warm', () async {
      _stubTarball(mockHttp, {kPubspecFileName: _kPubspecYaml});
      await registry.sourceFiles.resolve((name: 'http', version: '1.6.0'));

      await buildHandler().handleReadResource(_pubspecRequest('http'));

      // Only the warm-up fetch above ran — the handler call itself was a hit.
      verify(() => mockHttp.send(any())).called(1);
    });

    test('returns the pre-warmed source cache content', () async {
      _stubTarball(mockHttp, {kPubspecFileName: 'name: from_cache\n'});
      await registry.sourceFiles.resolve((name: 'http', version: '1.6.0'));

      final result = await buildHandler().handleReadResource(_pubspecRequest('http'));
      expect(_body(result!), equals('name: from_cache\n'));
    });

    test('warms the sourceFiles facade entry for (name, resolvedVersion)', () async {
      _stubTarball(mockHttp, {kPubspecFileName: _kPubspecYaml});
      await buildHandler().handleReadResource(_pubspecRequest('http'));
      expect(await registry.sourceFiles.peek((name: 'http', version: '1.6.0')), isNotNull);
    });
  });

  // ─── Pubspec resource: error paths ───────────────────────────────────────────

  group('pubspec resource error paths', () {
    test('returns package_not_found when the tarball endpoint returns 404', () async {
      _stubTarball(mockHttp, const {}, packageName: 'missing', statusCode: 404);
      final result = await buildHandler().handleReadResource(_pubspecRequest('missing'));
      expect(_errorPayload(result!)['code'], equals(DomainErrors.packageNotFound));
    });

    test('error payload contains a suggestion on 404', () async {
      _stubTarball(mockHttp, const {}, packageName: 'missing', statusCode: 404);
      final result = await buildHandler().handleReadResource(_pubspecRequest('missing'));
      expect(_errorPayload(result!), contains('suggestion'));
    });

    test('propagates package_not_found when version resolution returns 404', () async {
      _stubPackageInfo(mockHttp, packageName: 'missing', statusCode: 404);
      final result = await buildHandler().handleReadResource(
        _pubspecRequest('missing', version: 'latest'),
      );
      expect(_errorPayload(result!)['code'], equals(DomainErrors.packageNotFound));
    });

    test('does not download the tarball when version resolution fails', () async {
      _stubPackageInfo(mockHttp, packageName: 'missing', statusCode: 404);
      await buildHandler().handleReadResource(_pubspecRequest('missing', version: 'latest'));
      verifyNever(() => mockHttp.send(any()));
    });

    test('returns unexpected_response when pubspec.yaml is absent from the archive', () async {
      _stubTarball(mockHttp, {'lib/http.dart': 'void main() {}'});
      final result = await buildHandler().handleReadResource(_pubspecRequest('http'));
      expect(_errorPayload(result!)['code'], equals(DomainErrors.unexpectedResponse));
    });
  });

  // ─── Facade warm-up ───────────────────────────────────────────────────────────

  // The `api` resource and `BrowseApiSymbolsHandler` (and its three siblings)
  // resolve the dartdoc index through the same `CacheRegistry`-owned `apiIndex`
  // facade, so the two warm each other's cache. See
  // issues/keyed-cache/06-remaining-single-owner-caches.md.
  group('facade warm-up', () {
    test('api resource warms the apiIndex facade entry for (name, resolvedVersion)', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp);
      await buildHandler().handleReadResource(_apiRequest('http'));
      expect(await registry.apiIndex.peek((name: 'http', version: '1.6.0')), isNotNull);
    });

    test('readme resource warms the readme facade entry for (name, kind)', () async {
      _stubDocsPage(mockHttp);
      await buildHandler().handleReadResource(_readmeRequest('http'));
      expect(await registry.readme.peek((name: 'http', kind: ReadmeKind.readme)), isNotNull);
    });
  });

  // ─── Client error propagation ─────────────────────────────────────────────────

  group('client error propagation for readme resource', () {
    test('returns a rate_limited error payload when pub.dev returns HTTP 429', () async {
      _stubDocsPage(mockHttp, statusCode: 429);
      final result = await buildHandler().handleReadResource(_readmeRequest('http'));
      expect(_errorPayload(result!)['code'], equals(DomainErrors.rateLimited));
    });

    test('returns a service_unavailable error payload on HTTP 503', () async {
      _stubDocsPage(mockHttp, statusCode: 503);
      final result = await buildHandler().handleReadResource(_readmeRequest('http'));
      expect(_errorPayload(result!)['code'], equals(DomainErrors.serviceUnavailable));
    });
  });

  group('client error propagation for example resource', () {
    test('returns a rate_limited error payload when pub.dev returns HTTP 429', () async {
      _stubExamplePage(mockHttp, statusCode: 429);
      final result = await buildHandler().handleReadResource(_exampleRequest('http'));
      expect(_errorPayload(result!)['code'], equals(DomainErrors.rateLimited));
    });

    test('returns a service_unavailable error payload on HTTP 503', () async {
      _stubExamplePage(mockHttp, statusCode: 503);
      final result = await buildHandler().handleReadResource(_exampleRequest('http'));
      expect(_errorPayload(result!)['code'], equals(DomainErrors.serviceUnavailable));
    });

    test('returns package_not_found in the error payload on 404', () async {
      _stubExamplePage(mockHttp, statusCode: 404, packageName: 'missing');
      final result = await buildHandler().handleReadResource(_exampleRequest('missing'));
      expect(_errorPayload(result!)['code'], equals(DomainErrors.packageNotFound));
    });
  });

  group('client error propagation for changelog resource', () {
    test('returns a rate_limited error payload when pub.dev returns HTTP 429', () async {
      _stubChangelogPage(mockHttp, statusCode: 429);
      final result = await buildHandler().handleReadResource(_changelogRequest('http'));
      expect(_errorPayload(result!)['code'], equals(DomainErrors.rateLimited));
    });

    test('returns a service_unavailable error payload on HTTP 503', () async {
      _stubChangelogPage(mockHttp, statusCode: 503);
      final result = await buildHandler().handleReadResource(_changelogRequest('http'));
      expect(_errorPayload(result!)['code'], equals(DomainErrors.serviceUnavailable));
    });

    test('returns package_not_found in the error payload on 404', () async {
      _stubChangelogPage(mockHttp, statusCode: 404, packageName: 'missing');
      final result = await buildHandler().handleReadResource(_changelogRequest('missing'));
      expect(_errorPayload(result!)['code'], equals(DomainErrors.packageNotFound));
    });
  });

  group('client error propagation for api resource', () {
    test('returns a rate_limited error payload when pub.dev returns HTTP 429', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp, statusCode: 429);
      final result = await buildHandler().handleReadResource(_apiRequest('http'));
      expect(_errorPayload(result!)['code'], equals(DomainErrors.rateLimited));
    });

    test('returns a service_unavailable error payload on HTTP 503', () async {
      _stubPackageInfo(mockHttp);
      _stubIndexJson(mockHttp, statusCode: 503);
      final result = await buildHandler().handleReadResource(_apiRequest('http'));
      expect(_errorPayload(result!)['code'], equals(DomainErrors.serviceUnavailable));
    });
  });

  // ─── Completions ─────────────────────────────────────────────────────────────
  //
  // CompletionsSupport for {name} lives in the server (PubMcpServer.handleComplete),
  // reading through the searchResults KeyedCache facade (see pub_mcp_test.dart's
  // "handleComplete against warm facades" group). KeyedCache.entries delegates
  // straight to the underlying ResponseCache.entries this scan builds on, which
  // is what's tested here in isolation.

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
