/// Unit tests for [GetPackageSourceFileHandler].
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dart_mcp/server.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:pubdev_context/src/cache/memory_cache.dart';
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

http.Response _tarGzResponse(Map<String, String> files) {
  final bytes = _buildTarGz(files);
  return http.Response.bytes(bytes, 200);
}

/// Stubs a successful tarball fetch for [name] at [version].
void _stubTarball(
  _MockHttpClient mock,
  Map<String, String> files, {
  String name = 'foo',
  String version = '1.0.0',
}) {
  when(
    () => mock.get(
      any(
        that: predicate<Uri>(
          (u) => u.toString().contains('/api/packages/$name/versions/$version/archive.tar.gz'),
        ),
      ),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer((_) async => _tarGzResponse(files));
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

Map<String, Object?> _errorPayload(CallToolResult result) =>
    jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;

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
      expect(_errorPayload(result)['error'], equals('package_not_found'));
    });
  });

  // ─── Path validation ───────────────────────────────────────────────────────

  group('path validation', () {
    test('rejects paths with ".." segments', () async {
      final result = await buildHandler().call(
        _request({'name': 'foo', 'version': '1.0.0', 'path': '../etc/passwd'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['error'], equals('invalid_input'));
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
      expect(_errorPayload(result)['error'], equals('source_file_not_found'));
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
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/archive.tar.gz'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => _notFound());

      final result = await buildHandler().call(
        _request({'name': 'missing', 'version': '1.0.0', 'path': 'lib/src/foo.dart'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['error'], equals('package_not_found'));
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
        () => mockHttp.get(
          any(
            that: predicate<Uri>((u) => u.toString().contains('/archive.tar.gz')),
          ),
          headers: any(named: 'headers'),
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
