/// Unit tests for [ListSdkSourceFilesHandler].
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:dart_pubdev_mcp/src/analysis/ast_access.dart';
import 'package:dart_pubdev_mcp/src/cache/cache_registry.dart';
import 'package:dart_pubdev_mcp/src/data/domain_error.dart';
import 'package:dart_pubdev_mcp/src/tools/get_sdk_source_slice.dart';
import 'package:dart_pubdev_mcp/src/tools/list_sdk_source_files.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';
import '../../support/pub_stubs.dart';

// ─── Fixtures ─────────────────────────────────────────────────────────────────

/// Raw (repo-relative, GitHub-wrapper-stripped) tarball entries spanning two
/// `dart:` libraries — mirrors what `SdkClient.getSourceFiles` returns before
/// `CacheRegistry` normalizes the `sdk/` prefix away and drops non-`sdk/`
/// entries (`tests/...`).
const Map<String, String> _rawFiles = {
  'sdk/lib/core/list.dart': 'class MyList {}',
  'sdk/lib/core/map.dart': 'class MyMap {}',
  'sdk/lib/async/future.dart': 'class MyFuture {}',
  'tests/README.md': '# not part of an installed SDK',
};

/// Flutter framework files spanning two packages, already
/// installed-layout-shaped (`packages/<name>/lib/...`) — no `CacheRegistry`
/// normalization applies to the Flutter path (see ADR 0006).
const Map<String, String> _flutterFiles = {
  'packages/flutter/lib/src/widgets/framework.dart': 'abstract class Widget {}',
  'packages/flutter/lib/src/widgets/widget.dart': 'abstract class State {}',
  'packages/flutter_test/lib/flutter_test.dart': 'class WidgetTester {}',
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'list_sdk_source_files', arguments: args);

Map<String, Object?> _payload(CallToolResult result) =>
    jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;

List<String> _paths(CallToolResult result) =>
    ((_payload(result)['paths'] as List<Object?>?) ?? const []).cast<String>();

Map<String, Object?> _errorPayload(CallToolResult result) {
  final outer = _payload(result);
  final inner = outer['error'];
  if (inner is! Map<String, Object?>) throw StateError('No nested error object');
  return inner;
}

void main() {
  late TestStack stack;
  late MockHttpClient mockHttp;
  late CacheRegistry registry;

  ListSdkSourceFilesHandler buildHandler({
    String? platformVersion,
    Map<String, String>? flutterEnvironment,
  }) => ListSdkSourceFilesHandler(
    astAccess: AstAccess(sourceFiles: registry.sdkSourceFiles, ast: registry.sdkAst),
    log: (_, _) {},
    platformVersion: platformVersion == null ? null : () => platformVersion,
    flutterEnvironment: flutterEnvironment,
  );

  setUp(() {
    stack = TestStack();
    mockHttp = stack.http;
    registry = stack.caches;
  });

  tearDown(() => stack.close());

  // ─── Dart: library filter ───────────────────────────────────────────────────

  group('dart library filter', () {
    test('returns every file path under the given library', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'library': 'core', 'version': '3.12.2'}),
      );

      expect(result.isError, isNull);
      expect(_paths(result), equals(['lib/core/list.dart', 'lib/core/map.dart']));
    });

    test('response includes sdk, library, and resolvedVersion', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'library': 'core', 'version': '3.12.2'}),
      );

      final payload = _payload(result);
      expect(payload['sdk'], equals('dart'));
      expect(payload['library'], equals('core'));
      expect(payload['resolvedVersion'], equals('3.12.2'));
      expect(payload.containsKey('package'), isFalse);
    });

    test('returns every file when library is omitted', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'version': '3.12.2'}),
      );

      expect(
        _paths(result),
        equals(['lib/async/future.dart', 'lib/core/list.dart', 'lib/core/map.dart']),
      );
    });

    test('file paths are sorted alphabetically', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'version': '3.12.2'}),
      );

      final paths = _paths(result);
      expect(paths, equals([...paths]..sort()));
    });
  });

  // ─── Flutter: package filter ────────────────────────────────────────────────

  group('flutter package filter', () {
    test('returns every file path under the given package', () async {
      stubSdkTarball(mockHttp, _flutterFiles, owner: 'flutter', repo: 'flutter', ref: '3.35.1');

      final result = await buildHandler().call(
        _request({'sdk': 'flutter', 'package': 'flutter_test', 'version': '3.35.1'}),
      );

      expect(result.isError, isNull);
      expect(_paths(result), equals(['packages/flutter_test/lib/flutter_test.dart']));
    });

    test('response includes sdk, package, and resolvedVersion', () async {
      stubSdkTarball(mockHttp, _flutterFiles, owner: 'flutter', repo: 'flutter', ref: '3.35.1');

      final result = await buildHandler().call(
        _request({'sdk': 'flutter', 'package': 'flutter_test', 'version': '3.35.1'}),
      );

      final payload = _payload(result);
      expect(payload['sdk'], equals('flutter'));
      expect(payload['package'], equals('flutter_test'));
      expect(payload.containsKey('library'), isFalse);
    });

    test('returns every file when package is omitted', () async {
      stubSdkTarball(mockHttp, _flutterFiles, owner: 'flutter', repo: 'flutter', ref: '3.35.1');

      final result = await buildHandler().call(
        _request({'sdk': 'flutter', 'version': '3.35.1'}),
      );

      expect(_paths(result), hasLength(3));
    });
  });

  // ─── Directory and fileExtension filters ────────────────────────────────────

  group('directory and fileExtension filters', () {
    test('filters files by directory prefix', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'version': '3.12.2', 'directory': 'lib/core/'}),
      );

      expect(result.isError, isNull);
      expect(_paths(result), equals(['lib/core/list.dart', 'lib/core/map.dart']));
    });

    test('filters files by exact file path passed as directory', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'version': '3.12.2', 'directory': 'lib/core/list.dart'}),
      );

      expect(result.isError, isNull);
      expect(_paths(result), equals(['lib/core/list.dart']));
    });

    test('filters files by fileExtension', () async {
      stubSdkTarball(mockHttp, {
        ..._rawFiles,
        'sdk/lib/core/doc.md': '# documentation',
      });

      final mdResult = await buildHandler().call(
        _request({'sdk': 'dart', 'version': '3.12.2', 'fileExtension': '.md'}),
      );
      expect(mdResult.isError, isNull);
      expect(_paths(mdResult), equals(['lib/core/doc.md']));

      final dartResult = await buildHandler().call(
        _request({'sdk': 'dart', 'version': '3.12.2', 'fileExtension': '.dart'}),
      );
      expect(dartResult.isError, isNull);
      expect(
        _paths(dartResult),
        equals(['lib/async/future.dart', 'lib/core/list.dart', 'lib/core/map.dart']),
      );
    });

    test('filters files by both directory and fileExtension', () async {
      stubSdkTarball(mockHttp, {
        ..._rawFiles,
        'sdk/lib/core/doc.md': '# documentation',
        'sdk/lib/async/doc.md': '# async doc',
      });

      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'version': '3.12.2',
          'directory': 'lib/core',
          'fileExtension': '.dart',
        }),
      );

      expect(result.isError, isNull);
      expect(_paths(result), equals(['lib/core/list.dart', 'lib/core/map.dart']));
    });
  });

  // ─── Argument validation ─────────────────────────────────────────────────────

  group('argument validation', () {
    test('rejects sdk values other than "dart"/"flutter" with INVALID_ARGUMENT', () async {
      final result = await buildHandler().call(_request({'sdk': 'kotlin'}));

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('rejects a library containing a path separator with INVALID_ARGUMENT', () async {
      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'library': 'core/nested'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('rejects a package containing a path separator with INVALID_ARGUMENT', () async {
      final result = await buildHandler().call(
        _request({'sdk': 'flutter', 'package': 'flutter/nested'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });
  });

  // ─── Version resolution ─────────────────────────────────────────────────────

  group('version resolution', () {
    test('auto-detects the ref from Platform.version when version is omitted', () async {
      stubSdkTarball(mockHttp, _rawFiles, ref: '3.9.0');

      final result = await buildHandler(
        platformVersion: '3.9.0 (stable) (...) on "linux_x64"',
      ).call(_request({'sdk': 'dart', 'library': 'core'}));

      expect(result.isError, isNull);
      expect(_payload(result)['resolvedVersion'], equals('3.9.0'));
    });

    test('returns SDK_VERSION_NOT_FOUND for an unresolvable explicit version', () async {
      stubSdkTarball(mockHttp, _rawFiles, ref: '999.0.0', statusCode: 404);

      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'library': 'core', 'version': '999.0.0'}),
      );

      expect(result.isError, isTrue);
      final error = _errorPayload(result);
      expect(error['code'], equals(DomainErrors.sdkVersionNotFound));
      expect((error['details'] as Map<String, Object?>?)?['sdk'], equals('dart'));
    });

    test('returns SDK_NOT_DETECTED when no Flutter install is found', () async {
      final result = await buildHandler(flutterEnvironment: const {}).call(
        _request({'sdk': 'flutter', 'package': 'flutter'}),
      );

      expect(result.isError, isTrue);
      final error = _errorPayload(result);
      expect(error['code'], equals(DomainErrors.sdkNotDetected));
      expect((error['details'] as Map<String, Object?>?)?['sdk'], equals('flutter'));
    });

    test('auto-detects the ref from a fixture flutter.version.json via FLUTTER_ROOT', () async {
      final flutterRoot = Directory.systemTemp.createTempSync(
        'list_sdk_source_files_flutter_root_test_',
      );
      addTearDown(() {
        if (flutterRoot.existsSync()) flutterRoot.deleteSync(recursive: true);
      });
      final cacheDir = Directory('${flutterRoot.path}/bin/cache')..createSync(recursive: true);
      File(
        '${cacheDir.path}/flutter.version.json',
      ).writeAsStringSync('{"frameworkVersion": "3.29.0"}');

      stubSdkTarball(mockHttp, _flutterFiles, owner: 'flutter', repo: 'flutter', ref: '3.29.0');

      final result = await buildHandler(
        flutterEnvironment: {'FLUTTER_ROOT': flutterRoot.path},
      ).call(_request({'sdk': 'flutter', 'package': 'flutter'}));

      expect(result.isError, isNull);
      expect(_payload(result)['resolvedVersion'], equals('3.29.0'));
    });
  });

  // ─── Cache sharing with get_sdk_source_slice ────────────────────────────────

  group('cache sharing', () {
    test('triggers no second tarball download after a get_sdk_source_slice call', () async {
      stubSdkTarball(mockHttp, _rawFiles);
      final astAccess = AstAccess(sourceFiles: registry.sdkSourceFiles, ast: registry.sdkAst);
      final sliceHandler = GetSdkSourceSliceHandler(astAccess: astAccess, log: (_, _) {});
      final listHandler = ListSdkSourceFilesHandler(astAccess: astAccess, log: (_, _) {});

      await sliceHandler.call(
        CallToolRequest(
          name: 'get_sdk_source_slice',
          arguments: {
            'sdk': 'dart',
            'library': 'core',
            'path': 'list.dart',
            'version': '3.12.2',
          },
        ),
      );
      await listHandler.call(
        _request({'sdk': 'dart', 'library': 'core', 'version': '3.12.2'}),
      );

      verify(
        () => mockHttp.send(
          any(
            that: predicate<http.BaseRequest>(
              (r) => r.url.toString().contains('/dart-lang/sdk/tar.gz/'),
            ),
          ),
        ),
      ).called(1);
    });
  });
}
