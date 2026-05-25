// ignore_for_file: missing_whitespace_between_adjacent_strings for html fixtures

/// Unit tests for [PubDevClient].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:pubdev_context/src/cache/tarball_disk_cache.dart';
import 'package:pubdev_context/src/data/domain_error.dart';
import 'package:pubdev_context/src/data/models.dart';
import 'package:pubdev_context/src/data/pub_client.dart';
import 'package:test/test.dart';

// ─── Mocks ────────────────────────────────────────────────────────────────────

class _MockHttpClient extends Mock implements http.Client {}

// ─── Helpers ──────────────────────────────────────────────────────────────────

String _readFixture(String name) => File('test/fixtures/$name').readAsStringSync();

http.Response _json(String body, {int status = 200}) => http.Response(body, status);

http.Response _jsonFile(String name, {int status = 200}) =>
    _json(_readFixture(name), status: status);

/// A [RetryPolicy] that never delays.
RetryPolicy get _instant => RetryPolicy(delay: (_) async {});

Uint8List _buildTarGz(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.string(entry.key, entry.value));
  }
  final tar = TarEncoder().encodeBytes(archive);
  return const GZipEncoder().encodeBytes(tar);
}

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

    test('sort pub_points maps to points', () async {
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
      final tempDir = Directory.systemTemp.createTempSync('pubdev_context_tarball_cache_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final cache = TarballDiskCache(directoryPath: tempDir.path);
      await cache.write(
        'foo',
        '1.0.0',
        _buildTarGz({'lib/src/foo.dart': 'void foo() {}'}),
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
      final tempDir = Directory.systemTemp.createTempSync('pubdev_context_tarball_cache_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final tarballBytes = _buildTarGz({'lib/src/foo.dart': 'void foo() {}'});
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
      final tempDir = Directory.systemTemp.createTempSync('pubdev_context_tarball_cache_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final validTarball = _buildTarGz({'lib/src/foo.dart': 'void foo() {}'});
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
}
