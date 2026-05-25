/// Unit tests for [GetPackageSourceFileHandler].
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
import 'package:pubdev_context/src/tools/get_package_source_file.dart';
import 'package:test/test.dart';

// ─── Mocks ────────────────────────────────────────────────────────────────────

class _MockHttpClient extends Mock implements http.Client {}

// ─── Helpers ──────────────────────────────────────────────────────────────────

http.Response _ok(String body) => http.Response(body, 200);
http.Response _notFound() => http.Response('Not Found', 404);

RetryPolicy get _instant => RetryPolicy(delay: (_) async {});

/// Builds a gzip-compressed tar archive from [files] (path → content).
Uint8List _buildTarGz(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.string(entry.key, entry.value));
  }
  final tar = TarEncoder().encodeBytes(archive);
  return const GZipEncoder().encodeBytes(tar);
}

/// Stubs a successful tarball fetch for [name] at [version].
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

/// Stubs a successful package-info fetch to resolve the latest version.
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

  // README doc page
  when(
    () => mock.get(
      any(
        that: predicate<Uri>((u) => u.toString().contains('/documentation/$name/')),
      ),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer((_) async => _notFound());
}

const _defaultFiles = {
  'lib/src/foo.dart': 'void foo() {}',
  'lib/src/bar.dart': 'void bar() {}',
  'README.md': '# foo',
};

CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'get_package_source_file', arguments: args);

Map<String, Object?> _errorPayload(CallToolResult result) {
  final outer = jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;
  final inner = outer['error'];
  if (inner is! Map<String, Object?>) throw StateError('No nested error object');
  return inner;
}

String _content(CallToolResult result) => (result.content.first as TextContent).text;

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late _MockHttpClient mockHttp;
  late PubDevClient client;
  late ResponseCache<Map<String, String>> cache;
  final loggedMessages = <(LoggingLevel, Object)>[];

  GetPackageSourceFileHandler buildHandler() => GetPackageSourceFileHandler(
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

  // ─── Successful file read ──────────────────────────────────────────────────

  group('successful file read', () {
    test('returns file content when path and version are supplied', () async {
      _stubTarball(mockHttp, _defaultFiles);

      final result = await buildHandler().call(
        _request({'name': 'foo', 'version': '1.0.0', 'path': 'lib/src/foo.dart'}),
      );

      expect(result.isError, isNull);
      expect(_content(result), equals('void foo() {}'));
    });

    test('strips leading slash from path', () async {
      _stubTarball(mockHttp, _defaultFiles);

      final result = await buildHandler().call(
        _request({'name': 'foo', 'version': '1.0.0', 'path': '/lib/src/foo.dart'}),
      );

      expect(result.isError, isNull);
      expect(_content(result), equals('void foo() {}'));
    });

    test('returns README at package root', () async {
      _stubTarball(mockHttp, _defaultFiles);

      final result = await buildHandler().call(
        _request({'name': 'foo', 'version': '1.0.0', 'path': 'README.md'}),
      );

      expect(_content(result), equals('# foo'));
    });
  });

  // ─── Version resolution ────────────────────────────────────────────────────

  group('version resolution', () {
    test('resolves latest version when version is omitted', () async {
      _stubPackageInfo(mockHttp, version: '2.0.0');
      _stubTarball(mockHttp, _defaultFiles, version: '2.0.0');

      final result = await buildHandler().call(
        _request({'name': 'foo', 'path': 'lib/src/foo.dart'}),
      );

      expect(result.isError, isNull);
      expect(_content(result), equals('void foo() {}'));
    });

    test('returns package_not_found when version resolution fails', () async {
      when(
        () => mockHttp.get(any(), headers: any(named: 'headers')),
      ).thenAnswer((_) async => _notFound());

      final result = await buildHandler().call(
        _request({'name': 'missing', 'path': 'lib/src/foo.dart'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));
    });
  });

  // ─── Path validation ───────────────────────────────────────────────────────

  group('path validation', () {
    test('rejects paths with ".." segments', () async {
      final result = await buildHandler().call(
        _request({'name': 'foo', 'version': '1.0.0', 'path': '../etc/passwd'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('invalid_input error contains a suggestion', () async {
      final result = await buildHandler().call(
        _request({'name': 'foo', 'version': '1.0.0', 'path': '../evil'}),
      );

      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  // ─── source_file_not_found ────────────────────────────────────────────────

  group('source_file_not_found', () {
    test('returns source_file_not_found for a missing path', () async {
      _stubTarball(mockHttp, _defaultFiles);

      final result = await buildHandler().call(
        _request({'name': 'foo', 'version': '1.0.0', 'path': 'lib/src/missing.dart'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.sourceFileNotFound));
    });

    test('suggestion includes filename match when a file with the same name exists', () async {
      _stubTarball(mockHttp, {'lib/src/server/foo.dart': 'content'});

      final result = await buildHandler().call(
        _request({'name': 'foo', 'version': '1.0.0', 'path': 'lib/foo.dart'}),
      );

      expect(
        _errorPayload(result)['suggestion'] as String?,
        contains('lib/src/server/foo.dart'),
      );
    });

    test('suggestion directs to list_package_source_files when no filename match', () async {
      _stubTarball(mockHttp, {'lib/src/bar.dart': 'content'});

      final result = await buildHandler().call(
        _request({'name': 'foo', 'version': '1.0.0', 'path': 'lib/src/totally_different.dart'}),
      );

      expect(
        _errorPayload(result)['suggestion'] as String?,
        contains('list_package_source_files'),
      );
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
        _request({'name': 'missing', 'version': '1.0.0', 'path': 'lib/src/foo.dart'}),
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
        _request({'name': 'too_big', 'version': '1.0.0', 'path': 'lib/src/foo.dart'}),
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

      await handler.call(_request({'name': 'foo', 'version': '1.0.0', 'path': 'lib/src/foo.dart'}));
      await handler.call(_request({'name': 'foo', 'version': '1.0.0', 'path': 'lib/src/bar.dart'}));

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

      await handler.call(_request({'name': 'foo', 'version': '1.0.0', 'path': 'lib/src/foo.dart'}));
      loggedMessages.clear();
      await handler.call(_request({'name': 'foo', 'version': '1.0.0', 'path': 'lib/src/bar.dart'}));

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
      final f1 = handler.call(
        _request({'name': 'foo', 'version': '1.0.0', 'path': 'lib/src/foo.dart'}),
      );
      final f2 = handler.call(
        _request({'name': 'foo', 'version': '1.0.0', 'path': 'lib/src/bar.dart'}),
      );

      // Deliver the response now that both calls are suspended on the shared
      // future.
      responseCompleter.complete(
        http.StreamedResponse(Stream.value(_buildTarGz(_defaultFiles)), 200),
      );

      final results = await Future.wait([f1, f2]);

      verify(() => mockHttp.send(any())).called(1);
      for (final result in results) {
        expect(result.isError, isNot(true));
      }
    });
  });

  // ─── Cache miss ───────────────────────────────────────────────────────────

  group('cache miss', () {
    test('logs a debug cache-miss message on first call', () async {
      _stubTarball(mockHttp, _defaultFiles);

      await buildHandler().call(
        _request({'name': 'foo', 'version': '1.0.0', 'path': 'lib/src/foo.dart'}),
      );

      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString());
      expect(debugLogs.any((m) => m.contains('cache miss')), isTrue);
    });

    test('logs an info HTTP-request message containing the package name', () async {
      _stubTarball(mockHttp, _defaultFiles);

      await buildHandler().call(
        _request({'name': 'foo', 'version': '1.0.0', 'path': 'lib/src/foo.dart'}),
      );

      final infoLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.info)
          .map((m) => m.$2.toString());
      expect(infoLogs.any((m) => m.contains('name=foo')), isTrue);
    });
  });
}
