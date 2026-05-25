/// Unit tests for [ListPackageSourceFilesHandler].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dart_mcp/server.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:pubdev_context/src/cache/memory_cache.dart';
import 'package:pubdev_context/src/data/domain_error.dart';
import 'package:pubdev_context/src/data/pub_client.dart';
import 'package:pubdev_context/src/tools/list_package_source_files.dart';
import 'package:test/test.dart';

// ─── Mocks ────────────────────────────────────────────────────────────────────

class _MockHttpClient extends Mock implements http.Client {}

// ─── Helpers ──────────────────────────────────────────────────────────────────

http.Response _ok(String body) => http.Response(body, 200);
http.Response _notFound() => http.Response('Not Found', 404);

RetryPolicy get _instant => RetryPolicy(delay: (_) async {});

Uint8List _buildTarGz(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.string(entry.key, entry.value));
  }
  final tar = TarEncoder().encodeBytes(archive);
  return const GZipEncoder().encodeBytes(tar);
}

void _stubTarball(
  _MockHttpClient mock,
  Map<String, String> files, {
  String name = 'foo',
  String version = '1.0.0',
}) {
  when(
    () => mock.send(
      any(
        that: predicate<http.BaseRequest>(
          (r) => r.url.toString().contains(
            '/api/packages/$name/versions/$version/archive.tar.gz',
          ),
        ),
      ),
    ),
  ).thenAnswer((_) async => http.StreamedResponse(Stream.value(_buildTarGz(files)), 200));
}

void _stubPackageInfo(_MockHttpClient mock, {String name = 'foo', String version = '1.0.0'}) {
  final body = jsonEncode({
    'name': name,
    'latest': {
      'version': version,
      'pubspec': {'name': name, 'version': version},
      'published': '2024-01-01T00:00:00Z',
    },
    'versions': [
      {
        'version': version,
        'pubspec': {'name': name, 'version': version},
        'published': '2024-01-01T00:00:00Z',
      },
    ],
  });
  final scoreBody = jsonEncode({
    'likeCount': 0,
    'popularityScore': 0.5,
    'grantedPoints': 100,
    'maxPoints': 130,
  });

  when(
    () => mock.get(
      any(that: predicate<Uri>((u) => u.toString().contains('/api/packages/$name/score'))),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer((_) async => _ok(scoreBody));

  when(
    () => mock.get(
      any(
        that: predicate<Uri>(
          (u) =>
              u.toString().contains('/api/packages/$name') &&
              !u.toString().contains('score') &&
              !u.toString().contains('versions') &&
              !u.toString().contains('archive'),
        ),
      ),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer((_) async => _ok(body));

  when(
    () => mock.get(
      any(that: predicate<Uri>((u) => u.toString().contains('/documentation/$name/'))),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer((_) async => _notFound());
}

const _defaultFiles = {
  'lib/src/foo.dart': 'void foo() {}',
  'lib/src/bar.dart': 'void bar() {}',
  'lib/src/server/server.dart': 'class Server {}',
  'README.md': '# foo',
  'CHANGELOG.md': '## 1.0.0',
};

CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'list_package_source_files', arguments: args);

Map<String, Object?> _payload(CallToolResult result) =>
    jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;

List<String> _files(CallToolResult result) =>
    (_payload(result)['files'] as List<Object?>?)!.cast<String>();

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
  late ResponseCache<Map<String, String>> cache;
  final loggedMessages = <(LoggingLevel, Object)>[];

  ListPackageSourceFilesHandler buildHandler() => ListPackageSourceFilesHandler(
    client: client,
    cache: cache,
    log: (level, data) => loggedMessages.add((level, data)),
  );

  setUp(() {
    mockHttp = _MockHttpClient();
    registerFallbackValue(Uri.parse('https://pub.dev'));
    registerFallbackValue(http.Request('GET', Uri.parse('https://pub.dev')));
    client = PubDevClient(httpClient: mockHttp, retryPolicy: _instant);
    cache = ResponseCache();
    loggedMessages.clear();
  });

  tearDown(() => client.close());

  // ─── Successful listing ────────────────────────────────────────────────────

  group('successful listing', () {
    test('returns all file paths when no filters are supplied', () async {
      _stubTarball(mockHttp, _defaultFiles);

      final result = await buildHandler().call(
        _request({'name': 'foo', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      expect(_files(result), hasLength(5));
    });

    test('response includes name and version fields', () async {
      _stubTarball(mockHttp, _defaultFiles);

      final result = await buildHandler().call(
        _request({'name': 'foo', 'version': '1.0.0'}),
      );

      final payload = _payload(result);
      expect(payload['name'], equals('foo'));
      expect(payload['version'], equals('1.0.0'));
    });

    test('file paths are sorted alphabetically', () async {
      _stubTarball(mockHttp, _defaultFiles);

      final result = await buildHandler().call(
        _request({'name': 'foo', 'version': '1.0.0'}),
      );

      final files = _files(result);
      expect(files, equals([...files]..sort()));
    });
  });

  // ─── directory filter ──────────────────────────────────────────────────────

  group('directory filter', () {
    test('returns only files under the given directory', () async {
      _stubTarball(mockHttp, _defaultFiles);

      final result = await buildHandler().call(
        _request({'name': 'foo', 'version': '1.0.0', 'directory': 'lib/src/'}),
      );

      for (final path in _files(result)) {
        expect(path, startsWith('lib/src/'));
      }
    });

    test('normalises directory without trailing slash', () async {
      _stubTarball(mockHttp, _defaultFiles);

      final result = await buildHandler().call(
        _request({'name': 'foo', 'version': '1.0.0', 'directory': 'lib/src'}),
      );

      expect(_files(result), hasLength(3));
    });

    test('filters to subdirectory', () async {
      _stubTarball(mockHttp, _defaultFiles);

      final result = await buildHandler().call(
        _request({'name': 'foo', 'version': '1.0.0', 'directory': 'lib/src/server/'}),
      );

      expect(_files(result), equals(['lib/src/server/server.dart']));
    });
  });

  // ─── fileExtension filter ──────────────────────────────────────────────────

  group('fileExtension filter', () {
    test('returns only files with the given extension', () async {
      _stubTarball(mockHttp, _defaultFiles);

      final result = await buildHandler().call(
        _request({'name': 'foo', 'version': '1.0.0', 'fileExtension': '.dart'}),
      );

      for (final path in _files(result)) {
        expect(path, endsWith('.dart'));
      }
    });

    test('extension filter excludes .md files', () async {
      _stubTarball(mockHttp, _defaultFiles);

      final result = await buildHandler().call(
        _request({'name': 'foo', 'version': '1.0.0', 'fileExtension': '.dart'}),
      );

      expect(_files(result).any((p) => p.endsWith('.md')), isFalse);
    });
  });

  // ─── combined filters ──────────────────────────────────────────────────────

  group('combined filters', () {
    test('applies both directory and fileExtension filters', () async {
      _stubTarball(mockHttp, {
        'lib/src/foo.dart': '',
        'lib/src/foo_test.md': '',
        'test/foo_test.dart': '',
      });

      final result = await buildHandler().call(
        _request({
          'name': 'foo',
          'version': '1.0.0',
          'directory': 'lib/src/',
          'fileExtension': '.dart',
        }),
      );

      expect(_files(result), equals(['lib/src/foo.dart']));
    });
  });

  // ─── version resolution ────────────────────────────────────────────────────

  group('version resolution', () {
    test('resolves latest version when version is omitted', () async {
      _stubPackageInfo(mockHttp, version: '2.0.0');
      _stubTarball(mockHttp, _defaultFiles, version: '2.0.0');

      final result = await buildHandler().call(
        _request({'name': 'foo'}),
      );

      expect(result.isError, isNull);
      expect(_payload(result)['version'], equals('2.0.0'));
    });
  });

  // ─── Package not found ────────────────────────────────────────────────────

  group('package not found', () {
    test('returns package_not_found when tarball returns 404', () async {
      when(
        () => mockHttp.send(
          any(
            that: predicate<http.BaseRequest>(
              (r) => r.url.toString().contains('/archive.tar.gz'),
            ),
          ),
        ),
      ).thenAnswer((_) async => http.StreamedResponse(const Stream.empty(), 404));

      final result = await buildHandler().call(
        _request({'name': 'missing', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));
    });
  });

  // ─── Package too large ───────────────────────────────────────────────────

  group('package too large', () {
    test('returns package_too_large when tarball exceeds 50MB', () async {
      final chunk = List<int>.filled(20 * 1024 * 1024, 0);
      when(
        () => mockHttp.send(
          any(
            that: predicate<http.BaseRequest>(
              (r) => r.url.toString().contains(
                '/api/packages/too_big/versions/1.0.0/archive.tar.gz',
              ),
            ),
          ),
        ),
      ).thenAnswer(
        (_) async => http.StreamedResponse(
          Stream<List<int>>.fromIterable([chunk, chunk, chunk]),
          200,
        ),
      );

      final result = await buildHandler().call(
        _request({'name': 'too_big', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageTooLarge));
    });
  });

  // ─── Cache hit ────────────────────────────────────────────────────────────

  group('cache hit', () {
    test('does not issue a second tarball request within the TTL window', () async {
      _stubTarball(mockHttp, _defaultFiles);
      final handler = buildHandler();

      await handler.call(_request({'name': 'foo', 'version': '1.0.0'}));
      await handler.call(_request({'name': 'foo', 'version': '1.0.0'}));

      verify(
        () => mockHttp.send(
          any(
            that: predicate<http.BaseRequest>(
              (r) => r.url.toString().contains('/archive.tar.gz'),
            ),
          ),
        ),
      ).called(1);
    });

    test('logs a debug cache-hit message on the second call', () async {
      _stubTarball(mockHttp, _defaultFiles);
      final handler = buildHandler();

      await handler.call(_request({'name': 'foo', 'version': '1.0.0'}));
      loggedMessages.clear();
      await handler.call(_request({'name': 'foo', 'version': '1.0.0'}));

      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString());
      expect(debugLogs.any((m) => m.contains('cache hit')), isTrue);
    });

    test('concurrent calls share one in-flight download (stampede prevention)', () async {
      // Use a Completer so the HTTP response is withheld until both calls have
      // had a chance to progress past their cache checks.
      final responseCompleter = Completer<http.StreamedResponse>();
      when(
        () => mockHttp.send(
          any(
            that: predicate<http.BaseRequest>(
              (r) => r.url.toString().contains('/archive.tar.gz'),
            ),
          ),
        ),
      ).thenAnswer((_) => responseCompleter.future);

      final handler = buildHandler();

      // Both futures are started in the same synchronous turn. f1 suspends at
      // `_http.send` only AFTER it has written the in-flight Completer into the
      // cache; f2 therefore sees a cache hit and joins the same Future rather
      // than issuing its own HTTP request.
      final f1 = handler.call(_request({'name': 'foo', 'version': '1.0.0'}));
      final f2 = handler.call(_request({'name': 'foo', 'version': '1.0.0'}));

      // Deliver the response now that both calls are suspended on the shared
      // future.
      responseCompleter.complete(
        http.StreamedResponse(Stream.value(_buildTarGz(_defaultFiles)), 200),
      );

      await Future.wait([f1, f2]);

      verify(() => mockHttp.send(any())).called(1);
    });
  });
}
