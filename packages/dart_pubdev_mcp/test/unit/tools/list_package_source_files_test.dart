/// Unit tests for [ListPackageSourceFilesHandler].
library;

import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:dart_pubdev_mcp/src/cache/cache_registry.dart';
import 'package:dart_pubdev_mcp/src/data/domain_error.dart';
import 'package:dart_pubdev_mcp/src/tools/list_package_source_files.dart';
import 'package:dart_pubdev_mcp/src/tools/version_resolver.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';
import '../../support/pub_stubs.dart';

// ─── Helpers ──────────────────────────────────────────────────────────────────

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
    ((_payload(result)['files'] as List<Object?>?) ?? const []).cast<String>();

Map<String, Object?> _errorPayload(CallToolResult result) {
  final outer = jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;
  final inner = outer['error'];
  if (inner is! Map<String, Object?>) throw StateError('No nested error object');
  return inner;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late TestStack stack;
  late MockHttpClient mockHttp;
  late VersionResolver versionResolver;
  late CacheRegistry registry;

  ListPackageSourceFilesHandler buildHandler() => ListPackageSourceFilesHandler(
    versionResolver: versionResolver,
    sourceFiles: registry.sourceFiles,
    log: (_, _) {},
  );

  setUp(() {
    stack = TestStack();
    mockHttp = stack.http;
    versionResolver = VersionResolver(client: stack.client, log: (_, _) {});
    registry = stack.caches;
  });

  tearDown(() => stack.close());

  // ─── Successful listing ────────────────────────────────────────────────────

  group('successful listing', () {
    test('returns all file paths when no filters are supplied', () async {
      stubTarball(mockHttp, _defaultFiles);

      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      expect(_files(result), hasLength(5));
    });

    test('response includes package and resolvedVersion fields', () async {
      stubTarball(mockHttp, _defaultFiles);

      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0'}),
      );

      final payload = _payload(result);
      expect(payload['package'], equals('foo'));
      expect(payload['resolvedVersion'], equals('1.0.0'));
    });

    test('file paths are sorted alphabetically', () async {
      stubTarball(mockHttp, _defaultFiles);

      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0'}),
      );

      final files = _files(result);
      expect(files, equals([...files]..sort()));
    });
  });

  // ─── directory filter ──────────────────────────────────────────────────────

  group('directory filter', () {
    test('returns only files under the given directory', () async {
      stubTarball(mockHttp, _defaultFiles);

      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0', 'directory': 'lib/src/'}),
      );

      for (final path in _files(result)) {
        expect(path, startsWith('lib/src/'));
      }
    });

    test('normalises directory without trailing slash', () async {
      stubTarball(mockHttp, _defaultFiles);

      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0', 'directory': 'lib/src'}),
      );

      expect(_files(result), hasLength(3));
    });

    test('filters to subdirectory', () async {
      stubTarball(mockHttp, _defaultFiles);

      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0', 'directory': 'lib/src/server/'}),
      );

      expect(_files(result), equals(['lib/src/server/server.dart']));
    });
  });

  // ─── fileExtension filter ──────────────────────────────────────────────────

  group('fileExtension filter', () {
    test('returns only files with the given extension', () async {
      stubTarball(mockHttp, _defaultFiles);

      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0', 'fileExtension': '.dart'}),
      );

      for (final path in _files(result)) {
        expect(path, endsWith('.dart'));
      }
    });

    test('extension filter excludes .md files', () async {
      stubTarball(mockHttp, _defaultFiles);

      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0', 'fileExtension': '.dart'}),
      );

      expect(_files(result).any((p) => p.endsWith('.md')), isFalse);
    });
  });

  // ─── combined filters ──────────────────────────────────────────────────────

  group('combined filters', () {
    test('applies both directory and fileExtension filters', () async {
      stubTarball(mockHttp, {
        'lib/src/foo.dart': '',
        'lib/src/foo_test.md': '',
        'test/foo_test.dart': '',
      });

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
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
      stubPackageInfo(mockHttp, packageName: 'foo', version: '2.0.0');
      stubTarball(mockHttp, _defaultFiles, version: '2.0.0');

      final result = await buildHandler().call(
        _request({'package': 'foo'}),
      );

      expect(result.isError, isNull);
      expect(_payload(result)['resolvedVersion'], equals('2.0.0'));
    });
  });

  // ─── Resolve failure (P1.18) ─────────────────────────────────────────────────
  //
  // When `version` is omitted the handler resolves the latest stable version
  // first. A failed resolution (404) must propagate as package_not_found and
  // short-circuit before any tarball download.

  group('resolve failure (version omitted)', () {
    /// Stubs `GET /api/packages/missing` (the resolve endpoint) to return 404.
    void stubResolve404() {
      when(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) =>
                  u.toString().contains('/api/packages/missing') &&
                  !u.toString().contains('score') &&
                  !u.toString().contains('versions') &&
                  !u.toString().contains('archive'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => notFound());
    }

    test('propagates package_not_found when resolution returns 404', () async {
      stubResolve404();

      final result = await buildHandler().call(_request({'package': 'missing'}));

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));
    });

    test('does not download the tarball when resolution fails', () async {
      stubResolve404();

      await buildHandler().call(_request({'package': 'missing'}));

      verifyNever(() => mockHttp.send(any()));
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
        _request({'package': 'missing', 'version': '1.0.0'}),
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
        _request({'package': 'too_big', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageTooLarge));
    });
  });

  // ─── Cache hit ────────────────────────────────────────────────────────────

  group('cache hit', () {
    test('does not issue a second tarball request within the TTL window', () async {
      stubTarball(mockHttp, _defaultFiles);
      final handler = buildHandler();

      await handler.call(_request({'package': 'foo', 'version': '1.0.0'}));
      await handler.call(_request({'package': 'foo', 'version': '1.0.0'}));

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
      final f1 = handler.call(_request({'package': 'foo', 'version': '1.0.0'}));
      final f2 = handler.call(_request({'package': 'foo', 'version': '1.0.0'}));

      // Deliver the response now that both calls are suspended on the shared
      // future.
      responseCompleter.complete(
        http.StreamedResponse(Stream.value(buildTarGz(_defaultFiles)), 200),
      );

      await Future.wait([f1, f2]);

      verify(() => mockHttp.send(any())).called(1);
    });
  });
}
