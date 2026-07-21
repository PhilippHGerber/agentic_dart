/// Unit tests for [GetSdkSourceSliceHandler].
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:dart_pubdev_mcp/src/analysis/ast_access.dart';
import 'package:dart_pubdev_mcp/src/cache/cache_registry.dart';
import 'package:dart_pubdev_mcp/src/data/domain_error.dart';
import 'package:dart_pubdev_mcp/src/tools/get_sdk_source_slice.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';
import '../../support/pub_stubs.dart';

// ─── Fixtures ─────────────────────────────────────────────────────────────────

/// A Dart source file with a class spanning lines 1–5 (trailing newline).
///
/// ```text
/// 1  class MyList {
/// 2    final int length;
/// 3
/// 4    MyList(this.length);
/// 5  }
/// ```
const _listSource =
    'class MyList {\n'
    '  final int length;\n'
    '\n'
    '  MyList(this.length);\n'
    '}\n';

/// A Dart source file with a class spanning lines 1–10 (trailing newline) —
/// mirrors `get_source_slice_test.dart`'s `_widgetSource` fixture, reused
/// here for symbol-bounded-mode parity checks.
///
/// ```text
/// 1  class Widget {
/// 2    final int id;
/// 3
/// 4    Widget(this.id);
/// 5
/// 6    int compute(int x) {
/// 7      final y = x * 2;
/// 8      return y + id;
/// 9    }
/// 10 }
/// ```
const _widgetSource =
    'class Widget {\n'
    '  final int id;\n'
    '\n'
    '  Widget(this.id);\n'
    '\n'
    '  int compute(int x) {\n'
    '    final y = x * 2;\n'
    '    return y + id;\n'
    '  }\n'
    '}\n';

/// Raw (repo-relative, GitHub-wrapper-stripped) tarball entries — mirrors
/// what `SdkClient.getSourceFiles` returns before `CacheRegistry` normalizes
/// the `sdk/` prefix away.
const Map<String, String> _rawFiles = {
  'sdk/lib/core/list.dart': _listSource,
  'sdk/lib/core/widget.dart': _widgetSource,
  'sdk/lib/core/README.md': '# core',
  'tests/README.md': '# not part of an installed SDK',
};

/// A Flutter framework file, already installed-layout-shaped
/// (`packages/<name>/lib/...`) — no `CacheRegistry` normalization applies to
/// the Flutter path (see ADR 0006).
const Map<String, String> _flutterFiles = {
  'packages/flutter/lib/src/widgets/framework.dart': _listSource,
  'packages/flutter/lib/src/widgets/widget.dart': _widgetSource,
  'packages/flutter/lib/src/widgets/README.md': '# widgets',
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'get_sdk_source_slice', arguments: args);

Map<String, Object?> _payload(CallToolResult result) =>
    jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;

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
  final loggedMessages = <(LoggingLevel, Object)>[];

  GetSdkSourceSliceHandler buildHandler({
    String? platformVersion,
    Map<String, String>? flutterEnvironment,
  }) => GetSdkSourceSliceHandler(
    astAccess: AstAccess(sourceFiles: registry.sdkSourceFiles, ast: registry.sdkAst),
    log: (level, data) => loggedMessages.add((level, data)),
    platformVersion: platformVersion == null ? null : () => platformVersion,
    flutterEnvironment: flutterEnvironment,
  );

  setUp(() {
    stack = TestStack();
    mockHttp = stack.http;
    registry = stack.caches;
    loggedMessages.clear();
  });

  tearDown(() => stack.close());

  // ─── Line-range mode ───────────────────────────────────────────────────────

  group('line-range mode', () {
    test('returns exactly the requested inclusive line range', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'file': 'list.dart',
          'version': '3.12.2',
          'lineStart': 2,
          'lineEnd': 4,
        }),
      );

      expect(result.isError, isNull);
      final payload = _payload(result);
      expect(payload['resolvedVersion'], equals('3.12.2'));
      expect(payload['sdk'], equals('dart'));
      expect(payload['library'], equals('core'));
      expect(payload['file'], equals('list.dart'));
      expect(payload['mode'], equals('line-range'));
      expect(payload['lineStart'], equals(2));
      expect(payload['effectiveLineEnd'], equals(4));
      expect(payload['truncated'], isFalse);
      expect(
        payload['content'],
        equals('  final int length;\n\n  MyList(this.length);'),
      );
    });

    test('returns the full file verbatim when both bounds are omitted', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'file': 'list.dart',
          'version': '3.12.2',
        }),
      );

      final payload = _payload(result);
      expect(payload['content'], equals(_listSource));
      expect(payload['lineStart'], equals(1));
      expect(payload['effectiveLineEnd'], equals(5));
    });

    test('normalizes the installed-style path, dropping non-lib/ tarball entries', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'library': 'core', 'file': 'README.md', 'version': '3.12.2'}),
      );

      expect(result.isError, isNull);
      expect(_payload(result)['content'], equals('# core'));
    });
  });

  // ─── Symbol-bounded mode ───────────────────────────────────────────────────

  group('symbol-bounded mode', () {
    test('returns the full class body when no maxLines is supplied', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'file': 'widget.dart',
          'version': '3.12.2',
          'symbolName': 'Widget',
        }),
      );

      expect(result.isError, isNull);
      final payload = _payload(result);
      expect(payload['mode'], equals('symbol'));
      expect(payload['symbolName'], equals('Widget'));
      expect(payload['lineStart'], equals(1));
      expect(payload['effectiveLineEnd'], equals(10));
      expect(payload['truncated'], isFalse);
      expect(payload['content'], equals(_widgetSource.trimRight()));
    });

    test('truncates to signature + omission comment + closing brace', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'file': 'widget.dart',
          'version': '3.12.2',
          'symbolName': 'Widget',
          'maxLines': 3,
        }),
      );

      final payload = _payload(result);
      expect(payload['truncated'], isTrue);
      expect(payload['effectiveLineEnd'], equals(10));
      expect(payload['content'], equals('class Widget {\n  // ... 8 lines omitted ...\n}'));
    });

    test('locates a class member via "ClassName.member"', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'file': 'widget.dart',
          'version': '3.12.2',
          'symbolName': 'Widget.compute',
        }),
      );

      final payload = _payload(result);
      expect(payload['lineStart'], equals(6));
      expect(payload['effectiveLineEnd'], equals(9));
      expect(payload['truncated'], isFalse);
      expect(
        payload['content'],
        equals('int compute(int x) {\n    final y = x * 2;\n    return y + id;\n  }'),
      );
    });

    test('resolves the unnamed constructor via "new"', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'file': 'widget.dart',
          'version': '3.12.2',
          'symbolName': 'Widget.new',
        }),
      );

      final payload = _payload(result);
      expect(payload['lineStart'], equals(4));
      expect(payload['content'], equals('Widget(this.id);'));
    });

    test('returns SYMBOL_NOT_FOUND for an unknown symbol', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'file': 'widget.dart',
          'version': '3.12.2',
          'symbolName': 'DoesNotExist',
        }),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
    });

    test('line-range mode is unaffected by symbol-bounded mode support', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'file': 'widget.dart',
          'version': '3.12.2',
          'lineStart': 6,
          'lineEnd': 9,
        }),
      );

      final payload = _payload(result);
      expect(payload['mode'], equals('line-range'));
      expect(
        payload['content'],
        equals('  int compute(int x) {\n    final y = x * 2;\n    return y + id;\n  }'),
      );
    });
  });

  // ─── Version resolution ────────────────────────────────────────────────────

  group('version resolution', () {
    test('auto-detects the ref from Platform.version when version is omitted', () async {
      stubSdkTarball(mockHttp, _rawFiles, ref: '3.9.0');

      final result = await buildHandler(
        platformVersion: '3.9.0 (stable) (...) on "linux_x64"',
      ).call(_request({'sdk': 'dart', 'library': 'core', 'file': 'list.dart'}));

      expect(result.isError, isNull);
      expect(_payload(result)['resolvedVersion'], equals('3.9.0'));
    });

    test('honors an explicit version override over the auto-detected one', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler(platformVersion: '3.9.0 (stable) (...) on "linux_x64"')
          .call(
            _request({
              'sdk': 'dart',
              'library': 'core',
              'file': 'list.dart',
              'version': '3.12.2',
            }),
          );

      expect(result.isError, isNull);
      expect(_payload(result)['resolvedVersion'], equals('3.12.2'));
    });

    test('returns SDK_VERSION_NOT_FOUND for an unresolvable explicit version', () async {
      stubSdkTarball(mockHttp, _rawFiles, ref: '999.0.0', statusCode: 404);

      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'file': 'list.dart',
          'version': '999.0.0',
        }),
      );

      expect(result.isError, isTrue);
      final error = _errorPayload(result);
      expect(error['code'], equals(DomainErrors.sdkVersionNotFound));
      expect(error['retryable'], isFalse);
      expect((error['details'] as Map<String, Object?>?)?['sdk'], equals('dart'));
    });
  });

  // ─── Argument validation ───────────────────────────────────────────────────

  group('argument validation', () {
    test('rejects sdk values other than "dart"/"flutter" with INVALID_ARGUMENT', () async {
      final result = await buildHandler().call(
        _request({'sdk': 'kotlin', 'library': 'core', 'file': 'foo.dart'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('rejects a missing library with INVALID_ARGUMENT', () async {
      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'file': 'list.dart'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('rejects a library containing a path separator with INVALID_ARGUMENT', () async {
      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'library': 'core/nested', 'file': 'list.dart'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('rejects a missing file with INVALID_ARGUMENT', () async {
      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'library': 'core'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('rejects a file containing ".." with INVALID_ARGUMENT', () async {
      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'library': 'core', 'file': '../../etc/passwd'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });
  });

  // ─── Flutter: line-range mode ───────────────────────────────────────────────

  group('flutter line-range mode', () {
    test('returns exactly the requested inclusive line range', () async {
      stubSdkTarball(mockHttp, _flutterFiles, owner: 'flutter', repo: 'flutter', ref: '3.35.1');

      final result = await buildHandler().call(
        _request({
          'sdk': 'flutter',
          'package': 'flutter',
          'file': 'src/widgets/framework.dart',
          'version': '3.35.1',
          'lineStart': 2,
          'lineEnd': 4,
        }),
      );

      expect(result.isError, isNull);
      final payload = _payload(result);
      expect(payload['resolvedVersion'], equals('3.35.1'));
      expect(payload['sdk'], equals('flutter'));
      expect(payload['package'], equals('flutter'));
      expect(payload.containsKey('library'), isFalse);
      expect(payload['file'], equals('src/widgets/framework.dart'));
      expect(payload['mode'], equals('line-range'));
      expect(payload['lineStart'], equals(2));
      expect(payload['effectiveLineEnd'], equals(4));
      expect(payload['truncated'], isFalse);
      expect(
        payload['content'],
        equals('  final int length;\n\n  MyList(this.length);'),
      );
    });

    test('does not require the sdk/ tarball-prefix stripping the Dart path needs', () async {
      stubSdkTarball(mockHttp, _flutterFiles, owner: 'flutter', repo: 'flutter', ref: '3.35.1');

      final result = await buildHandler().call(
        _request({
          'sdk': 'flutter',
          'package': 'flutter',
          'file': 'src/widgets/README.md',
          'version': '3.35.1',
        }),
      );

      expect(result.isError, isNull);
      expect(_payload(result)['content'], equals('# widgets'));
    });
  });

  // ─── Flutter: symbol-bounded mode ──────────────────────────────────────────

  group('flutter symbol-bounded mode', () {
    test('returns the full class body when no maxLines is supplied', () async {
      stubSdkTarball(mockHttp, _flutterFiles, owner: 'flutter', repo: 'flutter', ref: '3.35.1');

      final result = await buildHandler().call(
        _request({
          'sdk': 'flutter',
          'package': 'flutter',
          'file': 'src/widgets/widget.dart',
          'version': '3.35.1',
          'symbolName': 'Widget',
        }),
      );

      expect(result.isError, isNull);
      final payload = _payload(result);
      expect(payload['mode'], equals('symbol'));
      expect(payload['symbolName'], equals('Widget'));
      expect(payload['lineStart'], equals(1));
      expect(payload['effectiveLineEnd'], equals(10));
      expect(payload['truncated'], isFalse);
      expect(payload['content'], equals(_widgetSource.trimRight()));
    });

    test('locates a class member via "ClassName.member"', () async {
      stubSdkTarball(mockHttp, _flutterFiles, owner: 'flutter', repo: 'flutter', ref: '3.35.1');

      final result = await buildHandler().call(
        _request({
          'sdk': 'flutter',
          'package': 'flutter',
          'file': 'src/widgets/widget.dart',
          'version': '3.35.1',
          'symbolName': 'Widget.compute',
          'maxLines': 2,
        }),
      );

      final payload = _payload(result);
      expect(payload['truncated'], isTrue);
      expect(
        payload['content'],
        equals('int compute(int x) {\n    // ... 2 lines omitted ...\n  }'),
      );
    });

    test('returns SYMBOL_NOT_FOUND for an unknown symbol', () async {
      stubSdkTarball(mockHttp, _flutterFiles, owner: 'flutter', repo: 'flutter', ref: '3.35.1');

      final result = await buildHandler().call(
        _request({
          'sdk': 'flutter',
          'package': 'flutter',
          'file': 'src/widgets/widget.dart',
          'version': '3.35.1',
          'symbolName': 'DoesNotExist',
        }),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
    });
  });

  // ─── Flutter: version resolution ───────────────────────────────────────────

  group('flutter version resolution', () {
    late Directory flutterRoot;

    setUp(() {
      flutterRoot = Directory.systemTemp.createTempSync(
        'get_sdk_source_slice_flutter_root_test_',
      );
    });

    tearDown(() {
      if (flutterRoot.existsSync()) flutterRoot.deleteSync(recursive: true);
    });

    void writeVersionFile(String frameworkVersion) {
      final cacheDir = Directory('${flutterRoot.path}/bin/cache')..createSync(recursive: true);
      File(
        '${cacheDir.path}/flutter.version.json',
      ).writeAsStringSync('{"frameworkVersion": "$frameworkVersion"}');
    }

    test('auto-detects the ref from a fixture flutter.version.json via FLUTTER_ROOT', () async {
      writeVersionFile('3.29.0');
      stubSdkTarball(mockHttp, _flutterFiles, owner: 'flutter', repo: 'flutter', ref: '3.29.0');

      final result = await buildHandler(flutterEnvironment: {'FLUTTER_ROOT': flutterRoot.path})
          .call(
            _request({
              'sdk': 'flutter',
              'package': 'flutter',
              'file': 'src/widgets/framework.dart',
            }),
          );

      expect(result.isError, isNull);
      expect(_payload(result)['resolvedVersion'], equals('3.29.0'));
    });

    test('honors an explicit version override over auto-detection', () async {
      writeVersionFile('3.29.0');
      stubSdkTarball(mockHttp, _flutterFiles, owner: 'flutter', repo: 'flutter', ref: '3.35.1');

      final result = await buildHandler(flutterEnvironment: {'FLUTTER_ROOT': flutterRoot.path})
          .call(
            _request({
              'sdk': 'flutter',
              'package': 'flutter',
              'file': 'src/widgets/framework.dart',
              'version': '3.35.1',
            }),
          );

      expect(result.isError, isNull);
      expect(_payload(result)['resolvedVersion'], equals('3.35.1'));
    });

    test('returns SDK_NOT_DETECTED when no install is found and no version is given', () async {
      final result = await buildHandler(flutterEnvironment: const {}).call(
        _request({
          'sdk': 'flutter',
          'package': 'flutter',
          'file': 'src/widgets/framework.dart',
        }),
      );

      expect(result.isError, isTrue);
      final error = _errorPayload(result);
      expect(error['code'], equals(DomainErrors.sdkNotDetected));
      expect(error['retryable'], isFalse);
      expect((error['details'] as Map<String, Object?>?)?['sdk'], equals('flutter'));
      verifyNever(() => mockHttp.send(any()));
    });

    test('returns SDK_VERSION_NOT_FOUND for an unresolvable explicit Flutter version', () async {
      stubSdkTarball(
        mockHttp,
        _flutterFiles,
        owner: 'flutter',
        repo: 'flutter',
        ref: '999.0.0',
        statusCode: 404,
      );

      final result = await buildHandler().call(
        _request({
          'sdk': 'flutter',
          'package': 'flutter',
          'file': 'src/widgets/framework.dart',
          'version': '999.0.0',
        }),
      );

      expect(result.isError, isTrue);
      final error = _errorPayload(result);
      expect(error['code'], equals(DomainErrors.sdkVersionNotFound));
      expect(error['retryable'], isFalse);
      expect((error['details'] as Map<String, Object?>?)?['sdk'], equals('flutter'));
    });
  });

  // ─── Flutter: argument validation ──────────────────────────────────────────

  group('flutter argument validation', () {
    test('rejects a missing package with INVALID_ARGUMENT', () async {
      final result = await buildHandler().call(
        _request({'sdk': 'flutter', 'file': 'framework.dart'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('rejects a package containing a path separator with INVALID_ARGUMENT', () async {
      final result = await buildHandler().call(
        _request({'sdk': 'flutter', 'package': 'flutter/nested', 'file': 'framework.dart'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('rejects a missing file with INVALID_ARGUMENT', () async {
      final result = await buildHandler().call(
        _request({'sdk': 'flutter', 'package': 'flutter'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });
  });

  // ─── source_file_not_found ─────────────────────────────────────────────────

  group('source_file_not_found', () {
    test('returns SOURCE_FILE_NOT_FOUND for a missing path', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'file': 'does_not_exist.dart',
          'version': '3.12.2',
        }),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.sourceFileNotFound));
    });
  });

  // ─── Caching ───────────────────────────────────────────────────────────────

  group('caching', () {
    test('does not issue a second tarball request within the TTL window', () async {
      stubSdkTarball(mockHttp, _rawFiles);
      final handler = buildHandler();

      await handler.call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'file': 'list.dart',
          'version': '3.12.2',
        }),
      );
      await handler.call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'file': 'README.md',
          'version': '3.12.2',
        }),
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
