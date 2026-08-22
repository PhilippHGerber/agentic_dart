// ignore_for_file: missing_whitespace_between_adjacent_strings for html fixtures

/// Unit tests for [PubDevClient].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_pubdev_mcp/src/cache/memory_cache.dart';
import 'package:dart_pubdev_mcp/src/cache/tarball_disk_cache.dart';
import 'package:dart_pubdev_mcp/src/data/domain_error.dart';
import 'package:dart_pubdev_mcp/src/data/models.dart';
import 'package:dart_pubdev_mcp/src/data/pub_client.dart';
import 'package:dart_pubdev_mcp/src/trace/wire_trace.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/pub_stubs.dart' show buildTarGz;

// ─── Mocks ────────────────────────────────────────────────────────────────────

class _MockHttpClient extends Mock implements http.Client {}

/// A [WireTraceSink] that records emitted lines in memory.
final class _RecordingSink implements WireTraceSink {
  final List<String> lines = <String>[];

  @override
  void writeLine(String line) => lines.add(line);

  @override
  void close() {}
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

String _readFixture(String name) => File('test/fixtures/$name').readAsStringSync();

http.Response _json(String body, {int status = 200}) => http.Response(body, status);

http.Response _jsonFile(String name, {int status = 200}) =>
    _json(_readFixture(name), status: status);

/// A [RetryPolicy] that never delays.
RetryPolicy get _instant => RetryPolicy(delay: (_) async {});

void _stubTarballStream(
  _MockHttpClient mock,
  List<int> bytes, {
  String name = 'foo',
  String version = '1.0.0',
}) {
  when(
    () => mock.send(
      any(
        that: predicate<http.BaseRequest>(
          (r) =>
              r.method == 'GET' &&
              r.url.toString().contains('/api/packages/$name/versions/$version/archive.tar.gz'),
        ),
      ),
    ),
  ).thenAnswer((_) async => http.StreamedResponse(Stream.value(bytes), 200));
}

// ─── Setup ────────────────────────────────────────────────────────────────────

_MockHttpClient _setUp() {
  final mock = _MockHttpClient();
  registerFallbackValue(Uri.parse('https://pub.dev'));
  registerFallbackValue(http.Request('GET', Uri.parse('https://pub.dev')));
  return mock;
}

void _stubGet(
  _MockHttpClient mock,
  String urlSubstring,
  http.Response response,
) {
  when(
    () => mock.get(
      any(that: predicate<Uri>((u) => u.toString().contains(urlSubstring))),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer((_) async => response);
}

PubDevClient _client(_MockHttpClient mock) => PubDevClient(httpClient: mock, retryPolicy: _instant);

void main() {
  // ─── getPackage ─────────────────────────────────────────────────────────────

  group('PubDevClient.getPackage', () {
    late _MockHttpClient mock;

    setUp(() {
      mock = _setUp();
      _stubGet(mock, '/api/packages/http', _jsonFile('package_info.json'));
      _stubGet(mock, '/api/packages/http/score', _jsonFile('package_score.json'));
      _stubGet(
        mock,
        '/documentation/http/latest/',
        _json(
          '<html><div class="desc markdown markdown-body"><p>A composable HTTP library.</p></div></html>',
        ),
      );
    });

    test('returns PubDevSuccess for a valid package', () async {
      final result = await _client(mock).getPackage('http');
      expect(result, isA<PubDevSuccess<PackageDetail>>());
    });

    test('name is http', () async {
      final detail =
          ((await _client(mock).getPackage('http')) as PubDevSuccess<PackageDetail>).value;
      expect(detail.name, equals('http'));
    });

    test('version is 1.6.0', () async {
      final detail =
          ((await _client(mock).getPackage('http')) as PubDevSuccess<PackageDetail>).value;
      expect(detail.version, equals('1.6.0'));
    });

    test('readmeExcerpt is populated from the docs page', () async {
      final detail =
          ((await _client(mock).getPackage('http')) as PubDevSuccess<PackageDetail>).value;
      expect(detail.readmeExcerpt, isNotEmpty);
    });

    test('returns package_not_found on 404', () async {
      _stubGet(mock, '/api/packages/nope', _json('', status: 404));
      _stubGet(mock, '/api/packages/nope/score', _json('', status: 404));
      _stubGet(mock, '/documentation/nope/latest/', _json('', status: 404));
      final result = await _client(mock).getPackage('nope');
      expect(
        (result as PubDevFailure<PackageDetail>).error.code,
        equals(DomainErrors.packageNotFound),
      );
    });

    test('includes Accept header in all requests', () async {
      await _client(mock).getPackage('http');
      verify(
        () => mock.get(
          any(),
          headers: any(
            named: 'headers',
            that: predicate<Map<String, String>>(
              (h) => h['Accept'] == 'application/vnd.pub.v2+json',
            ),
          ),
        ),
      ).called(greaterThanOrEqualTo(1));
    });
  });

  // ─── getPackageVersion ──────────────────────────────────────────────────────

  group('PubDevClient.getPackageVersion', () {
    late _MockHttpClient mock;
    final versionJson = jsonEncode({
      'version': '1.5.0',
      'pubspec': {
        'name': 'http',
        'version': '1.5.0',
        'description': 'A composable HTTP library.',
        'environment': {'sdk': '^3.4.0'},
        'dependencies': <String, Object?>{},
        'dev_dependencies': <String, Object?>{},
      },
      'published': '2025-08-07T22:35:23.863279Z',
    });

    setUp(() {
      mock = _setUp();
      _stubGet(mock, '/api/packages/http/versions/1.5.0', _json(versionJson));
      _stubGet(mock, '/api/packages/http/score', _jsonFile('package_score.json'));
    });

    test('returns PubDevSuccess for a valid version', () async {
      final result = await _client(mock).getPackageVersion('http', '1.5.0');
      expect(result, isA<PubDevSuccess<PackageDetail>>());
    });

    test('version field matches requested version', () async {
      final detail =
          ((await _client(mock).getPackageVersion('http', '1.5.0')) as PubDevSuccess<PackageDetail>)
              .value;
      expect(detail.version, equals('1.5.0'));
    });

    test('returns package_not_found on 404', () async {
      _stubGet(mock, '/api/packages/http/versions/0.0.0', _json('', status: 404));
      final result = await _client(mock).getPackageVersion('http', '0.0.0');
      expect(result, isA<PubDevFailure<PackageDetail>>());
    });
  });

  // ─── search ─────────────────────────────────────────────────────────────────

  group('PubDevClient.search', () {
    late _MockHttpClient mock;

    setUp(() {
      mock = _setUp();
      _stubGet(mock, '/api/search', _jsonFile('search_result.json'));
      _stubGet(mock, '/api/packages/', _jsonFile('package_info.json'));
      _stubGet(mock, '/score', _jsonFile('package_score.json'));
    });

    test('returns PubDevSuccess', () async {
      final result = await _client(mock).search('http');
      expect(result, isA<PubDevSuccess<List<PackageSummary>>>());
    });

    test('search failure returns PubDevFailure', () async {
      _stubGet(mock, '/api/search', _json('', status: 500));
      final result = await _client(mock).search('http');
      expect(result, isA<PubDevFailure<List<PackageSummary>>>());
    });

    test('sort relevance omits the sort parameter', () async {
      await _client(mock).search('http');
      verify(
        () => mock.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/api/search') && !u.toString().contains('sort='),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('sort likes maps to like', () async {
      await _client(mock).search('http', sort: 'likes');
      verify(
        () => mock.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('sort=like'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('sort pubPoints maps to points', () async {
      await _client(mock).search('http', sort: 'pubPoints');
      verify(
        () => mock.get(
          any(
            that: predicate<Uri>((u) => u.toString().contains('sort=points')),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('sort pub_points maps to points for backward compatibility', () async {
      await _client(mock).search('http', sort: 'pub_points');
      verify(
        () => mock.get(
          any(
            that: predicate<Uri>((u) => u.toString().contains('sort=points')),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('sort updated maps to recent', () async {
      await _client(mock).search('http', sort: 'updated');
      verify(
        () => mock.get(
          any(
            that: predicate<Uri>((u) => u.toString().contains('sort=recent')),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('sdk parameter is forwarded', () async {
      await _client(mock).search('http', sdk: 'flutter');
      verify(
        () => mock.get(
          any(
            that: predicate<Uri>((u) => u.toString().contains('sdk=flutter')),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('platform parameter is forwarded', () async {
      await _client(mock).search('http', platform: 'android');
      verify(
        () => mock.get(
          any(
            that: predicate<Uri>((u) => u.toString().contains('platform=android')),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('page > 1 adds page parameter', () async {
      await _client(mock).search('http', page: 2);
      verify(
        () => mock.get(
          any(
            that: predicate<Uri>((u) => u.toString().contains('page=2')),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });
  });

  // ─── getScore ───────────────────────────────────────────────────────────────

  group('PubDevClient.getScore', () {
    late _MockHttpClient mock;

    setUp(() {
      mock = _setUp();
      _stubGet(mock, '/api/packages/http/score', _jsonFile('package_score.json'));
    });

    test('returns PubDevSuccess', () async {
      expect(await _client(mock).getScore('http'), isA<PubDevSuccess<PackageScore>>());
    });

    test('likes field matches fixture', () async {
      final score = ((await _client(mock).getScore('http')) as PubDevSuccess<PackageScore>).value;
      expect(score.likes, equals(8435));
    });

    test('returns PubDevFailure on 404', () async {
      _stubGet(mock, '/api/packages/missing/score', _json('', status: 404));
      expect(
        await _client(mock).getScore('missing'),
        isA<PubDevFailure<PackageScore>>(),
      );
    });
  });

  // ─── getMetrics ─────────────────────────────────────────────────────────────

  group('PubDevClient.getMetrics', () {
    late _MockHttpClient mock;

    setUp(() {
      mock = _setUp();
      _stubGet(
        mock,
        '/api/packages/http/metrics',
        _jsonFile('package_metrics.json'),
      );
    });

    test('returns PubDevSuccess', () async {
      expect(
        await _client(mock).getMetrics('http'),
        isA<PubDevSuccess<PackageMetrics>>(),
      );
    });

    test('packageVersion field matches fixture', () async {
      final metrics =
          ((await _client(mock).getMetrics('http')) as PubDevSuccess<PackageMetrics>).value;
      expect(metrics.packageVersion, equals('1.6.0'));
    });

    test('returns PubDevFailure on 404', () async {
      _stubGet(mock, '/api/packages/missing/metrics', _json('', status: 404));
      expect(
        await _client(mock).getMetrics('missing'),
        isA<PubDevFailure<PackageMetrics>>(),
      );
    });
  });

  // ─── getSecurityAdvisories ──────────────────────────────────────────────────

  group('PubDevClient.getSecurityAdvisories', () {
    late _MockHttpClient mock;

    const oneAdvisoryBody = '''
{
  "advisories": [
    {
      "id": "GHSA-4rgh-jx4f-qfcq",
      "aliases": ["CVE-2020-35669"],
      "summary": "http before 0.13.3 vulnerable to header injection",
      "affected": [
        {
          "package": {"ecosystem": "Pub", "name": "http"},
          "ranges": [
            {"type": "ECOSYSTEM", "events": [{"introduced": "0"}, {"fixed": "0.13.3"}]}
          ]
        }
      ],
      "database_specific": {"pub_display_url": "https://github.com/advisories/GHSA-4rgh-jx4f-qfcq"}
    }
  ],
  "advisoriesUpdated": "2026-05-04T16:03:47.124153Z"
}
''';

    setUp(() {
      mock = _setUp();
      _stubGet(mock, '/api/packages/http/advisories', _json(oneAdvisoryBody));
    });

    test('returns PubDevSuccess', () async {
      expect(
        await _client(mock).getSecurityAdvisories('http'),
        isA<PubDevSuccess<List<SecurityAdvisory>>>(),
      );
    });

    test('parses one advisory', () async {
      final advisories =
          ((await _client(mock).getSecurityAdvisories('http'))
                  as PubDevSuccess<List<SecurityAdvisory>>)
              .value;
      expect(advisories, hasLength(1));
    });

    test('advisory id matches fixture', () async {
      final advisories =
          ((await _client(mock).getSecurityAdvisories('http'))
                  as PubDevSuccess<List<SecurityAdvisory>>)
              .value;
      expect(advisories.first.id, equals('GHSA-4rgh-jx4f-qfcq'));
    });

    test('returns an empty list for a package with no advisories', () async {
      _stubGet(
        mock,
        '/api/packages/json_annotation/advisories',
        _json('{"advisories": [], "advisoriesUpdated": "1970-01-01T00:00:00.000"}'),
      );
      final advisories =
          ((await _client(mock).getSecurityAdvisories('json_annotation'))
                  as PubDevSuccess<List<SecurityAdvisory>>)
              .value;
      expect(advisories, isEmpty);
    });

    test('returns PubDevFailure on 404', () async {
      _stubGet(mock, '/api/packages/missing/advisories', _json('', status: 404));
      expect(
        await _client(mock).getSecurityAdvisories('missing'),
        isA<PubDevFailure<List<SecurityAdvisory>>>(),
      );
    });

    test('404 failure carries PACKAGE_NOT_FOUND', () async {
      _stubGet(mock, '/api/packages/missing/advisories', _json('', status: 404));
      final result =
          await _client(mock).getSecurityAdvisories('missing') as PubDevFailure<List<SecurityAdvisory>>;
      expect(result.error.code, equals(DomainErrors.packageNotFound));
    });
  });

  // ─── getApiIndex ────────────────────────────────────────────────────────────

  group('PubDevClient.getApiIndex', () {
    late _MockHttpClient mock;

    setUp(() {
      mock = _setUp();
      _stubGet(
        mock,
        '/documentation/http/latest/index.json',
        _jsonFile('index_json.json'),
      );
    });

    test('returns PubDevSuccess', () async {
      expect(
        await _client(mock).getApiIndex('http'),
        isA<PubDevSuccess<List<DartdocSymbol>>>(),
      );
    });

    test('result list is non-empty', () async {
      final symbols =
          ((await _client(mock).getApiIndex('http')) as PubDevSuccess<List<DartdocSymbol>>).value;
      expect(symbols, isNotEmpty);
    });

    test('each symbol has a non-empty name', () async {
      final symbols =
          ((await _client(mock).getApiIndex('http')) as PubDevSuccess<List<DartdocSymbol>>).value;
      expect(symbols.every((s) => s.name.isNotEmpty), isTrue);
    });

    test('returns PubDevFailure on 404', () async {
      _stubGet(
        mock,
        '/documentation/missing/latest/index.json',
        _json('', status: 404),
      );
      expect(
        await _client(mock).getApiIndex('missing'),
        isA<PubDevFailure<List<DartdocSymbol>>>(),
      );
    });
  });

  // ─── getReadme ──────────────────────────────────────────────────────────────

  group('PubDevClient.getReadme', () {
    late _MockHttpClient mock;
    const html =
        '<html><div class="desc markdown markdown-body"><p>A composable HTTP library for Dart.</p></div></html>';

    setUp(() {
      mock = _setUp();
      _stubGet(mock, '/documentation/http/latest/', _json(html));
    });

    test('returns PubDevSuccess', () async {
      expect(
        await _client(mock).getReadme('http'),
        isA<PubDevSuccess<String>>(),
      );
    });

    test('extracted text contains meaningful content', () async {
      final readme = ((await _client(mock).getReadme('http')) as PubDevSuccess<String>).value;
      expect(readme, contains('composable'));
    });

    test('returns PubDevFailure on 404', () async {
      _stubGet(mock, '/documentation/missing/latest/', _json('', status: 404));
      expect(
        await _client(mock).getReadme('missing'),
        isA<PubDevFailure<String>>(),
      );
    });
  });

  // ─── getExample ─────────────────────────────────────────────────────────────

  group('PubDevClient.getExample', () {
    late _MockHttpClient mock;
    const html =
        '<html><body>'
        '<div class="detail-tabs-content">'
        '<section class="tab-content detail-tab-example-content -active markdown-body">'
        '<p class="-monospace"><a href="https://github.com/dart-lang/http/blob/master/pkgs/http/example/main.dart">example/main.dart</a></p>'
        '<pre><code class="language-dart">main() { print(\'example\'); }</code></pre>'
        '</section>'
        '</div>'
        '</body></html>';

    setUp(() {
      mock = _setUp();
      _stubGet(mock, '/packages/http/example', _json(html));
    });

    test('returns PubDevSuccess', () async {
      expect(await _client(mock).getExample('http'), isA<PubDevSuccess<String>>());
    });

    test('extracted text contains the example code', () async {
      final example = ((await _client(mock).getExample('http')) as PubDevSuccess<String>).value;
      expect(example, contains("main() { print('example'); }"));
    });

    test('returns example_not_found when the example section is absent', () async {
      _stubGet(mock, '/packages/missing/example', _json('<html><body></body></html>'));
      final result = await _client(mock).getExample('missing');
      expect((result as PubDevFailure<String>).error.code, equals(DomainErrors.exampleNotFound));
    });

    test('returns package_not_found on 404', () async {
      _stubGet(mock, '/packages/nope/example', _json('', status: 404));
      final result = await _client(mock).getExample('nope');
      expect((result as PubDevFailure<String>).error.code, equals(DomainErrors.packageNotFound));
    });
  });

  // ─── unexpected_response ────────────────────────────────────────────────────

  group('PubDevClient — malformed JSON responses', () {
    test('returns unexpected_response when score body is a JSON array not a map', () async {
      final mock = _setUp();
      _stubGet(mock, '/api/packages/http/score', _json('[1,2,3]'));
      final result = await _client(mock).getScore('http');
      expect(
        (result as PubDevFailure<PackageScore>).error.code,
        equals(DomainErrors.unexpectedResponse),
      );
    });

    test('returns unexpected_response when package body is a JSON array not a map', () async {
      final mock = _setUp();
      _stubGet(mock, '/api/packages/http', _json('[1,2,3]'));
      _stubGet(mock, '/api/packages/http/score', _jsonFile('package_score.json'));
      _stubGet(mock, '/documentation/http/latest/', _json(''));
      final result = await _client(mock).getPackage('http');
      expect(
        (result as PubDevFailure<PackageDetail>).error.code,
        equals(DomainErrors.unexpectedResponse),
      );
    });

    test('returns unexpected_response when api index body is a JSON map not an array', () async {
      final mock = _setUp();
      _stubGet(mock, '/documentation/http/latest/index.json', _json('{"key":"value"}'));
      final result = await _client(mock).getApiIndex('http');
      expect(
        (result as PubDevFailure<List<DartdocSymbol>>).error.code,
        equals(DomainErrors.unexpectedResponse),
      );
    });
  });

  // ─── close ──────────────────────────────────────────────────────────────────

  group('PubDevClient.getPackageSourceFiles', () {
    test('uses tarball disk cache before making HTTP requests', () async {
      final mock = _setUp();
      final tempDir = Directory.systemTemp.createTempSync('dart_pubdev_mcp_tarball_cache_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final cache = TarballDiskCache(directoryPath: tempDir.path);
      await cache.write(
        'foo',
        '1.0.0',
        buildTarGz({'lib/src/foo.dart': 'void foo() {}'}),
      );

      final client = PubDevClient(
        httpClient: mock,
        retryPolicy: _instant,
        tarballCache: cache,
      );

      final result = await client.getPackageSourceFiles('foo', '1.0.0');
      expect(result, isA<PubDevSuccess<Map<String, String>>>());
      final files = (result as PubDevSuccess<Map<String, String>>).value;
      expect(files['lib/src/foo.dart'], equals('void foo() {}'));

      verifyNever(() => mock.get(any(), headers: any(named: 'headers')));
      verifyNever(() => mock.send(any()));
    });

    test('returns package_too_large when streamed tarball exceeds 50MB', () async {
      final mock = _setUp();
      final chunk = List<int>.filled(20 * 1024 * 1024, 1);

      when(
        () => mock.send(
          any(
            that: predicate<http.BaseRequest>(
              (r) => r.url.toString().contains('/api/packages/foo/versions/1.0.0/archive.tar.gz'),
            ),
          ),
        ),
      ).thenAnswer(
        (_) async => http.StreamedResponse(
          Stream<List<int>>.fromIterable([chunk, chunk, chunk]),
          200,
        ),
      );

      final client = PubDevClient(httpClient: mock, retryPolicy: _instant);
      final result = await client.getPackageSourceFiles('foo', '1.0.0');

      expect(result, isA<PubDevFailure<Map<String, String>>>());
      final error = (result as PubDevFailure<Map<String, String>>).error;
      expect(error.code, equals(DomainErrors.packageTooLarge));
    });

    test('stores downloaded tarball in disk cache for subsequent calls', () async {
      final mock = _setUp();
      final tempDir = Directory.systemTemp.createTempSync('dart_pubdev_mcp_tarball_cache_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final tarballBytes = buildTarGz({'lib/src/foo.dart': 'void foo() {}'});
      _stubTarballStream(mock, tarballBytes);

      final cache = TarballDiskCache(directoryPath: tempDir.path);
      final client = PubDevClient(
        httpClient: mock,
        retryPolicy: _instant,
        tarballCache: cache,
      );

      final first = await client.getPackageSourceFiles('foo', '1.0.0');
      expect(first, isA<PubDevSuccess<Map<String, String>>>());
      verify(() => mock.send(any())).called(1);

      final second = await client.getPackageSourceFiles('foo', '1.0.0');
      expect(second, isA<PubDevSuccess<Map<String, String>>>());
      verifyNever(() => mock.get(any(), headers: any(named: 'headers')));
      verifyNoMoreInteractions(mock);
    });

    test('does not poison disk cache when the first downloaded tarball is malformed', () async {
      final mock = _setUp();
      final tempDir = Directory.systemTemp.createTempSync('dart_pubdev_mcp_tarball_cache_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final validTarball = buildTarGz({'lib/src/foo.dart': 'void foo() {}'});
      var calls = 0;
      when(
        () => mock.send(
          any(
            that: predicate<http.BaseRequest>(
              (r) => r.url.toString().contains('/api/packages/foo/versions/1.0.0/archive.tar.gz'),
            ),
          ),
        ),
      ).thenAnswer((_) async {
        calls++;
        return http.StreamedResponse(
          Stream.value(calls == 1 ? <int>[1, 2, 3, 4] : validTarball),
          200,
        );
      });

      final cache = TarballDiskCache(directoryPath: tempDir.path);
      final client = PubDevClient(
        httpClient: mock,
        retryPolicy: _instant,
        tarballCache: cache,
      );

      final first = await client.getPackageSourceFiles('foo', '1.0.0');
      expect(first, isA<PubDevFailure<Map<String, String>>>());
      expect(
        (first as PubDevFailure<Map<String, String>>).error.code,
        equals(DomainErrors.unexpectedResponse),
      );

      final second = await client.getPackageSourceFiles('foo', '1.0.0');
      expect(second, isA<PubDevSuccess<Map<String, String>>>());
      expect(
        (second as PubDevSuccess<Map<String, String>>).value['lib/src/foo.dart'],
        equals('void foo() {}'),
      );

      expect(calls, equals(2));
    });

    test('returns invalid_argument when name contains path traversal characters', () async {
      final client = _client(_setUp());
      final result = await client.getPackageSourceFiles('../evil', '1.0.0');
      expect(result, isA<PubDevFailure<Map<String, String>>>());
      expect(
        (result as PubDevFailure<Map<String, String>>).error.code,
        equals(DomainErrors.invalidArgument),
      );
    });

    test('returns invalid_argument when version contains a path separator', () async {
      final client = _client(_setUp());
      final result = await client.getPackageSourceFiles('foo', '1.0.0/../evil');
      expect(result, isA<PubDevFailure<Map<String, String>>>());
      expect(
        (result as PubDevFailure<Map<String, String>>).error.code,
        equals(DomainErrors.invalidArgument),
      );
    });
  });

  group('PubDevClient.close', () {
    test('delegates close to the underlying http client', () {
      final mock = _setUp();
      when(mock.close).thenReturn(null);
      _client(mock).close();
      verify(mock.close).called(1);
    });
  });

  // ─── Semaphore — concurrency limiter ────────────────────────────────────────

  group('PubDevClient — concurrency limiter', () {
    test('never exceeds maxConcurrency requests in flight', () async {
      final mock = _setUp();
      var inFlight = 0;
      var peak = 0;
      final resume = Completer<void>();

      when(
        () => mock.get(any(), headers: any(named: 'headers')),
      ).thenAnswer((_) async {
        inFlight++;
        if (inFlight > peak) peak = inFlight;
        await resume.future;
        inFlight--;
        return _jsonFile('package_score.json');
      });

      final client = PubDevClient(
        httpClient: mock,
        retryPolicy: _instant,
        maxConcurrency: 2,
      );

      // Fire 5 concurrent requests — all block on resume
      final futures = List.generate(5, (_) => client.getScore('http'));

      // Yield to the event loop so all futures proceed to their suspension point
      await Future<void>.delayed(Duration.zero);

      expect(peak, lessThanOrEqualTo(2));

      resume.complete();
      await Future.wait(futures);
    });

    test('all requests complete when maxConcurrency is high', () async {
      final mock = _setUp();
      when(
        () => mock.get(any(), headers: any(named: 'headers')),
      ).thenAnswer((_) async => _jsonFile('package_score.json'));

      final client = PubDevClient(
        httpClient: mock,
        retryPolicy: _instant,
        maxConcurrency: 20,
      );

      final results = await Future.wait(
        List.generate(10, (_) => client.getScore('http')),
      );
      expect(results.every((r) => r is PubDevSuccess<PackageScore>), isTrue);
    });
  });

  // ─── resolveLatestStable ────────────────────────────────────────────────────

  group('PubDevClient.resolveLatestStable', () {
    test('returns the newest non-pre-release version', () async {
      final mock = _setUp();
      // fixture has versions 1.4.0, 1.5.0-beta, 1.5.0-beta.2, 1.5.0, 1.6.0
      _stubGet(mock, '/api/packages/http', _jsonFile('package_info.json'));
      final result = await _client(mock).resolveLatestStable('http');
      expect((result as PubDevSuccess<String>).value, equals('1.6.0'));
    });

    test('skips pre-release versions that contain a hyphen', () async {
      final mock = _setUp();
      final body = jsonEncode({
        'versions': [
          {'version': '1.0.0'},
          {'version': '2.0.0-beta'},
          {'version': '2.0.0-rc.1'},
        ],
        'latest': {'version': '2.0.0-rc.1'},
      });
      _stubGet(mock, '/api/packages/http', _json(body));
      final result = await _client(mock).resolveLatestStable('http');
      expect((result as PubDevSuccess<String>).value, equals('1.0.0'));
    });

    test('falls back to latest.version when all versions are pre-releases', () async {
      final mock = _setUp();
      final body = jsonEncode({
        'versions': [
          {'version': '1.0.0-alpha'},
          {'version': '1.0.0-beta'},
        ],
        'latest': {'version': '1.0.0-beta'},
      });
      _stubGet(mock, '/api/packages/http', _json(body));
      final result = await _client(mock).resolveLatestStable('http');
      expect((result as PubDevSuccess<String>).value, equals('1.0.0-beta'));
    });

    test('returns package_not_found when the package does not exist', () async {
      final mock = _setUp();
      _stubGet(mock, '/api/packages/unknown', _json('', status: 404));
      final result = await _client(mock).resolveLatestStable('unknown');
      expect(
        (result as PubDevFailure<String>).error.code,
        equals(DomainErrors.packageNotFound),
      );
    });

    test(
      'returns unexpected_response when versions is empty and latest is absent',
      () async {
        final mock = _setUp();
        final body = jsonEncode({'versions': <Object?>[]});
        _stubGet(mock, '/api/packages/http', _json(body));
        final result = await _client(mock).resolveLatestStable('http');
        expect(
          (result as PubDevFailure<String>).error.code,
          equals(DomainErrors.unexpectedResponse),
        );
      },
    );

    test(
      'returns unexpected_response when versions and latest are both absent',
      () async {
        final mock = _setUp();
        _stubGet(mock, '/api/packages/http', _json(jsonEncode(<String, Object?>{})));
        final result = await _client(mock).resolveLatestStable('http');
        expect(
          (result as PubDevFailure<String>).error.code,
          equals(DomainErrors.unexpectedResponse),
        );
      },
    );

    test('skips malformed entries whose version is a non-string value', () async {
      final mock = _setUp();
      // The first (newest) entry has a non-string `version`; resolution must
      // skip it rather than throw, falling through to the next stable entry.
      final body = jsonEncode({
        'versions': [
          {'version': '1.0.0'},
          {'version': 42},
        ],
        'latest': {'version': '1.0.0'},
      });
      _stubGet(mock, '/api/packages/http', _json(body));
      final result = await _client(mock).resolveLatestStable('http');
      expect((result as PubDevSuccess<String>).value, equals('1.0.0'));
    });

    test('falls back to latest.version when every entry is malformed', () async {
      final mock = _setUp();
      final body = jsonEncode({
        'versions': [
          {'version': 42},
          {'noVersionKey': true},
        ],
        'latest': {'version': '3.1.4'},
      });
      _stubGet(mock, '/api/packages/http', _json(body));
      final result = await _client(mock).resolveLatestStable('http');
      expect((result as PubDevSuccess<String>).value, equals('3.1.4'));
    });
  });

  // ─── retry integration ──────────────────────────────────────────────────────

  group('PubDevClient — retry on 503', () {
    test('retries service errors and returns result on success', () async {
      final mock = _setUp();
      var calls = 0;
      when(
        () => mock.get(
          any(
            that: predicate<Uri>((u) => u.toString().contains('/api/packages/http/score')),
          ),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async {
        calls++;
        if (calls < 3) return _json('', status: 503);
        return _jsonFile('package_score.json');
      });

      final client = PubDevClient(httpClient: mock, retryPolicy: _instant);
      final result = await client.getScore('http');
      expect(result, isA<PubDevSuccess<PackageScore>>());
      expect(calls, equals(3));
    });
  });

  // ─── wire-trace logging ──────────────────────────────────────────────────────

  group('PubDevClient — wire-trace logging', () {
    late _RecordingSink sink;
    late WireTrace trace;

    setUp(() {
      sink = _RecordingSink();
      trace = WireTrace.withSink(
        sink,
        serverVersion: '0.0.0-test',
        maxPreviewBytes: 2048,
        concurrency: 5,
        cacheDir: '/tmp',
      );
    });

    /// Runs [body] as if inside a traced request carrying Correlation Id [id].
    Future<T> inTracedRequest<T>(String id, Future<T> Function() body) =>
        runZoned(body, zoneValues: {wireTraceZoneIdKey: id});

    List<String> pubLines() =>
        sink.lines.where((l) => l.contains('→ pub') || l.contains('← pub')).toList();

    test('logs the outbound request and response under the ambient Correlation Id', () async {
      final mock = _setUp();
      _stubGet(
        mock,
        '/api/packages/http/score',
        http.Response(
          _readFixture('package_score.json'),
          200,
          headers: const {'content-type': 'application/vnd.pub.v2+json'},
        ),
      );
      final client = PubDevClient(httpClient: mock, retryPolicy: _instant, trace: trace);

      await inTracedRequest('#042', () => client.getScore('http'));

      final request = sink.lines.firstWhere((l) => l.contains('→ pub'));
      final response = sink.lines.firstWhere((l) => l.contains('← pub'));
      expect(request, contains('#042'));
      expect(request, contains('GET /api/packages/http/score'));
      expect(response, contains('#042'));
      expect(response, contains('200 /api/packages/http/score'));
      // Response trailer carries latency, byte size, and a compact content type.
      expect(response, contains(' ms'));
      expect(response, contains('JSON'));
    });

    test('includes the full query string on the request line', () async {
      final mock = _setUp();
      _stubGet(
        mock,
        '/api/search',
        http.Response(
          '{"packages":[]}',
          200,
          headers: const {'content-type': 'application/json'},
        ),
      );
      final client = PubDevClient(httpClient: mock, retryPolicy: _instant, trace: trace);

      await inTracedRequest('#001', () => client.search('http client'));

      final request = sink.lines.firstWhere(
        (l) => l.contains('→ pub') && l.contains('/api/search'),
      );
      expect(request, contains('q=http+client'));
    });

    test('logs a non-200 response before the call fails', () async {
      final mock = _setUp();
      _stubGet(mock, '/api/packages/htp/score', http.Response('', 404));
      final client = PubDevClient(httpClient: mock, retryPolicy: _instant, trace: trace);

      await inTracedRequest('#009', () => client.getScore('htp'));

      expect(
        sink.lines.any((l) => l.contains('← pub') && l.contains('404')),
        isTrue,
      );
    });

    test('outside a traced request (no Correlation Id), nothing is logged', () async {
      final mock = _setUp();
      _stubGet(mock, '/api/packages/http/score', _jsonFile('package_score.json'));
      final client = PubDevClient(httpClient: mock, retryPolicy: _instant, trace: trace);

      await client.getScore('http');

      expect(pubLines(), isEmpty);
    });

    test('with no trace injected, nothing is built or logged', () async {
      final mock = _setUp();
      _stubGet(mock, '/api/packages/http/score', _jsonFile('package_score.json'));
      final client = PubDevClient(httpClient: mock, retryPolicy: _instant);

      await inTracedRequest('#001', () => client.getScore('http'));

      expect(pubLines(), isEmpty);
    });

    test('a JSON response is previewed as a body continuation line', () async {
      final mock = _setUp();
      _stubGet(
        mock,
        '/api/packages/http/score',
        http.Response(
          _readFixture('package_score.json'),
          200,
          headers: const {'content-type': 'application/vnd.pub.v2+json'},
        ),
      );
      final client = PubDevClient(httpClient: mock, retryPolicy: _instant, trace: trace);

      await inTracedRequest('#042', () => client.getScore('http'));

      final response = sink.lines.firstWhere((l) => l.contains('← pub'));
      expect(response, contains('#042'));
      // The preview carries the actual JSON the endpoint returned.
      final body = sink.lines.firstWhere((l) => l.contains('body:'));
      expect(body, contains('grantedPoints'));
    });

    test('a large JSON response is truncated with a total-size annotation', () async {
      final mock = _setUp();
      // A body far larger than the 32-byte cap forces truncation.
      final big = '{"data":"${'x' * 5000}"}';
      _stubGet(
        mock,
        '/api/packages/http/score',
        http.Response(big, 200, headers: const {'content-type': 'application/json'}),
      );
      final smallCapSink = _RecordingSink();
      final smallCapTrace = WireTrace.withSink(
        smallCapSink,
        serverVersion: '0.0.0-test',
        maxPreviewBytes: 32,
        concurrency: 5,
        cacheDir: '/tmp',
      );
      final client = PubDevClient(
        httpClient: mock,
        retryPolicy: _instant,
        trace: smallCapTrace,
      );

      await inTracedRequest('#001', () => client.getScore('http'));

      final body = smallCapSink.lines.firstWhere((l) => l.contains('body:'));
      expect(body, contains('(truncated,'));
      expect(body, contains('total)'));
    });

    test('an HTML endpoint logs the converted markdown, never the raw HTML', () async {
      final mock = _setUp();
      _stubGet(
        mock,
        '/packages/foo/changelog',
        _json(
          '<html><body><h2>1.0.0</h2><p>Initial release of foo.</p></body></html>',
        ),
      );
      final client = PubDevClient(httpClient: mock, retryPolicy: _instant, trace: trace);

      await inTracedRequest('#007', () => client.getChangelog('foo'));

      final response = sink.lines.firstWhere((l) => l.contains('← pub'));
      // Both sizes are annotated as an HTML → md conversion.
      expect(response, contains('HTML →'));
      expect(response, contains(' md'));
      // The converted markdown is previewed; the raw HTML never reaches the file.
      final body = sink.lines.firstWhere((l) => l.contains('body:'));
      expect(body, contains('1.0.0'));
      expect(sink.lines.any((l) => l.contains('<')), isFalse);
    });

    test('a tarball download logs size and file count, and no archive bytes', () async {
      final mock = _setUp();
      final bytes = buildTarGz({
        'foo-1.0.0/pubspec.yaml': 'name: foo\n',
        'foo-1.0.0/lib/foo.dart': 'class Foo {}\n',
      });
      _stubTarballStream(mock, bytes);
      final client = PubDevClient(httpClient: mock, retryPolicy: _instant, trace: trace);

      await inTracedRequest(
        '#011',
        () => client.getPackageSourceFiles('foo', '1.0.0'),
      );

      final response = sink.lines.firstWhere(
        (l) => l.contains('← pub') && l.contains('archive.tar.gz'),
      );
      expect(response, contains('#011'));
      expect(response, contains('tar.gz'));
      expect(response, contains('2 files'));
      // Metadata only: no body/archive content is ever written.
      expect(sink.lines.any((l) => l.contains('body:')), isFalse);
    });

    test('a transient failure logs a retry line and a [retry N] request', () async {
      final mock = _setUp();
      var calls = 0;
      when(
        () => mock.get(
          any(that: predicate<Uri>((u) => u.toString().contains('/api/packages/http/score'))),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async {
        calls++;
        if (calls == 1) return _json('', status: 503);
        return http.Response(
          _readFixture('package_score.json'),
          200,
          headers: const {'content-type': 'application/vnd.pub.v2+json'},
        );
      });
      final client = PubDevClient(httpClient: mock, retryPolicy: _instant, trace: trace);

      await inTracedRequest('#055', () => client.getScore('http'));

      final retry = sink.lines.firstWhere((l) => l.contains('⚠ pub'));
      expect(retry, contains('#055'));
      expect(retry, contains('503 /api/packages/http/score'));
      expect(retry, contains('retry 1/3 in 500 ms'));
      // The subsequent request line is tagged as a retry.
      expect(
        sink.lines.any((l) => l.contains('→ pub') && l.contains('[retry 1]')),
        isTrue,
      );
      // The retried 503 is rendered as the ⚠ line only — never also as a
      // `← pub 503`, which would duplicate it against the authoritative format.
      expect(
        sink.lines.where((l) => l.contains('← pub')).every((l) => l.contains('200')),
        isTrue,
      );
    });

    test(
      'an exhausted transient failure logs a final ← pub response, not a dangling request',
      () async {
        final mock = _setUp();
        // Every attempt 503s: two ⚠ retry lines, then a give-up ← pub line.
        _stubGet(mock, '/api/packages/http/score', _json('', status: 503));
        final client = PubDevClient(httpClient: mock, retryPolicy: _instant, trace: trace);

        await inTracedRequest('#077', () => client.getScore('http'));

        expect(sink.lines.where((l) => l.contains('⚠ pub')), hasLength(2));
        // The final failed attempt still gets one ← pub 503 line (the give-up),
        // so no request is left dangling without a response.
        final finals = sink.lines.where(
          (l) => l.contains('← pub') && l.contains('503 /api/packages/http/score'),
        );
        expect(finals, hasLength(1));
      },
    );

    test('--wire-trace-max-preview 0 produces metadata-only lines, no bodies', () async {
      final mock = _setUp();
      _stubGet(
        mock,
        '/api/packages/http/score',
        http.Response(
          _readFixture('package_score.json'),
          200,
          headers: const {'content-type': 'application/vnd.pub.v2+json'},
        ),
      );
      final metaSink = _RecordingSink();
      final metaTrace = WireTrace.withSink(
        metaSink,
        serverVersion: '0.0.0-test',
        maxPreviewBytes: 0,
        concurrency: 5,
        cacheDir: '/tmp',
      );
      final client = PubDevClient(httpClient: mock, retryPolicy: _instant, trace: metaTrace);

      await inTracedRequest('#001', () => client.getScore('http'));

      // The boundary lines are present…
      expect(metaSink.lines.any((l) => l.contains('← pub  200')), isTrue);
      // …but no body is ever written.
      expect(metaSink.lines.any((l) => l.contains('body:')), isFalse);
    });

    test('a mapped Tool Error surfaces its 404 status on the ← pub line', () async {
      final mock = _setUp();
      _stubGet(mock, '/api/packages/htp/score', _json('', status: 404));
      final client = PubDevClient(httpClient: mock, retryPolicy: _instant, trace: trace);

      final result = await inTracedRequest('#009', () => client.getScore('htp'));

      // The pub boundary shows the failing status…
      expect(
        sink.lines.any((l) => l.contains('← pub') && l.contains('404 /api/packages/htp/score')),
        isTrue,
      );
      // …and the client maps it to the ADR-0002 Tool Error the LLM boundary renders.
      expect(
        (result as PubDevFailure<PackageScore>).error.code,
        equals(DomainErrors.packageNotFound),
      );
    });
  });

  // ─── Package Info Cache ──────────────────────────────────────────────────────

  group('PubDevClient — Package Info Cache', () {
    /// Stubs the bare `GET /api/packages/$name` info endpoint (never `/score`
    /// or `/versions/…`) with [status] and the `package_info.json` fixture,
    /// counting every hit. Returns a getter for the observed call count.
    int Function() stubInfo(_MockHttpClient mock, String name, {int status = 200}) {
      var calls = 0;
      when(
        () => mock.get(
          any(that: predicate<Uri>((u) => u.path == '/api/packages/$name')),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async {
        calls++;
        return http.Response(_readFixture('package_info.json'), status);
      });
      return () => calls;
    }

    PubDevClient clientWithCache(
      _MockHttpClient mock, {
      WireTrace? trace,
    }) => PubDevClient(
      httpClient: mock,
      retryPolicy: _instant,
      packageInfoCache: ResponseCache<Map<String, Object?>>(trace: trace),
      trace: trace,
    );

    test('a cache miss fetches from pub.dev and returns the value', () async {
      final mock = _setUp();
      final infoCalls = stubInfo(mock, 'http');
      final client = clientWithCache(mock);

      final result = await client.resolveLatestStable('http');

      expect((result as PubDevSuccess<String>).value, equals('1.6.0'));
      expect(infoCalls(), equals(1));
    });

    test('a second resolveLatestStable within TTL serves from cache, no HTTP request', () async {
      final mock = _setUp();
      final infoCalls = stubInfo(mock, 'http');
      final client = clientWithCache(mock);

      final first = await client.resolveLatestStable('http');
      final second = await client.resolveLatestStable('http');

      expect((first as PubDevSuccess<String>).value, equals('1.6.0'));
      expect((second as PubDevSuccess<String>).value, equals('1.6.0'));
      expect(infoCalls(), equals(1));
    });

    test('a second listVersions within TTL serves from the same cached info payload', () async {
      final mock = _setUp();
      final infoCalls = stubInfo(mock, 'http');
      final client = clientWithCache(mock);

      final first = await client.listVersions('http');
      final second = await client.listVersions('http');

      expect(first, isA<PubDevSuccess<List<PackageVersion>>>());
      expect(second, isA<PubDevSuccess<List<PackageVersion>>>());
      expect(infoCalls(), equals(1));
    });

    test('resolveLatestStable and listVersions share one cached info fetch', () async {
      final mock = _setUp();
      final infoCalls = stubInfo(mock, 'http');
      final client = clientWithCache(mock);

      await client.resolveLatestStable('http');
      await client.listVersions('http');

      expect(infoCalls(), equals(1));
    });

    test('a cache hit emits a ⚡ cache hit line under the ambient Correlation Id', () async {
      final mock = _setUp();
      final infoCalls = stubInfo(mock, 'http');
      final sink = _RecordingSink();
      final trace = WireTrace.withSink(
        sink,
        serverVersion: '0.0.0-test',
        maxPreviewBytes: 2048,
        concurrency: 5,
        cacheDir: '/tmp',
      );
      final client = clientWithCache(mock, trace: trace);

      await runZoned(() async {
        await client.resolveLatestStable('http');
        await client.resolveLatestStable('http');
      }, zoneValues: {wireTraceZoneIdKey: '#100'});

      expect(infoCalls(), equals(1));
      expect(
        sink.lines.any((l) => l.contains('⚡ cache hit') && l.contains('http')),
        isTrue,
      );
    });

    test('resolveLatestStable then getPackage fetch the info endpoint only once', () async {
      final mock = _setUp();
      final infoCalls = stubInfo(mock, 'http');
      _stubGet(mock, '/api/packages/http/score', _jsonFile('package_score.json'));
      _stubGet(mock, '/documentation/http/latest/', _json('<html></html>'));
      final client = clientWithCache(mock);

      await client.resolveLatestStable('http');
      final pkg = await client.getPackage('http');

      expect(pkg, isA<PubDevSuccess<PackageDetail>>());
      expect(infoCalls(), equals(1));
    });

    test('two concurrent calls for the same package share one in-flight request', () async {
      final mock = _setUp();
      var calls = 0;
      final gate = Completer<void>();
      when(
        () => mock.get(
          any(that: predicate<Uri>((u) => u.path == '/api/packages/http')),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async {
        calls++;
        await gate.future;
        return http.Response(_readFixture('package_info.json'), 200);
      });
      final client = clientWithCache(mock);

      final futures = Future.wait([
        client.resolveLatestStable('http'),
        client.resolveLatestStable('http'),
      ]);
      gate.complete();
      final results = await futures;

      expect(results.every((r) => r is PubDevSuccess<String>), isTrue);
      expect(calls, equals(1));
    });

    test('a failed fetch is not cached — the next call retries against pub.dev', () async {
      final mock = _setUp();
      var calls = 0;
      when(
        () => mock.get(
          any(that: predicate<Uri>((u) => u.path == '/api/packages/http')),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async {
        calls++;
        return calls == 1
            ? http.Response('', 404)
            : http.Response(_readFixture('package_info.json'), 200);
      });
      final client = clientWithCache(mock);

      final first = await client.resolveLatestStable('http');
      final second = await client.resolveLatestStable('http');

      expect((first as PubDevFailure<String>).error.code, equals(DomainErrors.packageNotFound));
      expect((second as PubDevSuccess<String>).value, equals('1.6.0'));
      expect(calls, equals(2));
    });

    test('getScore is unaffected by the info cache — each call issues its own request', () async {
      final mock = _setUp();
      var scoreCalls = 0;
      when(
        () => mock.get(
          any(that: predicate<Uri>((u) => u.path == '/api/packages/http/score')),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async {
        scoreCalls++;
        return _jsonFile('package_score.json');
      });
      final client = clientWithCache(mock);

      await client.getScore('http');
      await client.getScore('http');

      expect(scoreCalls, equals(2));
    });

    test('getMetrics is unaffected by the info cache — each call issues its own request', () async {
      final mock = _setUp();
      var metricsCalls = 0;
      when(
        () => mock.get(
          any(that: predicate<Uri>((u) => u.path == '/api/packages/http/metrics')),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async {
        metricsCalls++;
        return _jsonFile('package_metrics.json');
      });
      final client = clientWithCache(mock);

      await client.getMetrics('http');
      await client.getMetrics('http');

      expect(metricsCalls, equals(2));
    });

    test(
      'getPackageVersion is unaffected by the info cache — the version endpoint is hit every call',
      () async {
        final mock = _setUp();
        final versionJson = jsonEncode({
          'version': '1.5.0',
          'pubspec': {
            'name': 'http',
            'version': '1.5.0',
            'description': 'A composable HTTP library.',
            'environment': {'sdk': '^3.4.0'},
            'dependencies': <String, Object?>{},
            'dev_dependencies': <String, Object?>{},
          },
          'published': '2025-08-07T22:35:23.863279Z',
        });
        var versionCalls = 0;
        when(
          () => mock.get(
            any(that: predicate<Uri>((u) => u.path == '/api/packages/http/versions/1.5.0')),
            headers: any(named: 'headers'),
          ),
        ).thenAnswer((_) async {
          versionCalls++;
          return _json(versionJson);
        });
        _stubGet(mock, '/api/packages/http/score', _jsonFile('package_score.json'));
        final client = clientWithCache(mock);

        await client.getPackageVersion('http', '1.5.0');
        await client.getPackageVersion('http', '1.5.0');

        expect(versionCalls, equals(2));
      },
    );
  });
}
