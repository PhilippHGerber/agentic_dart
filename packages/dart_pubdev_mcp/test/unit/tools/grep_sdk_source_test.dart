/// Unit tests for [GrepSdkSourceHandler].
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:dart_pubdev_mcp/src/analysis/ast_access.dart';
import 'package:dart_pubdev_mcp/src/cache/cache_registry.dart';
import 'package:dart_pubdev_mcp/src/data/domain_error.dart';
import 'package:dart_pubdev_mcp/src/tools/grep_sdk_source.dart';
import 'package:dart_pubdev_mcp/src/tools/tool_definitions.dart' show grepSdkSourceTool;
import 'package:test/test.dart';

import '../../support/harness.dart';
import '../../support/pub_stubs.dart';
import '../../support/schema_conformance.dart';

// ─── Fixtures ─────────────────────────────────────────────────────────────────

const Map<String, String> _rawFiles = {
  'sdk/lib/core/list.dart': 'class MyList {\n  void isEmpty() {}\n}\n',
  'sdk/lib/core/map.dart': 'class MyMap {\n  void isEmpty() {}\n}\n',
  'sdk/lib/async/future.dart': 'class MyFuture {}\n',
  'sdk/README.md': 'isEmpty mentioned in docs\n',
};

const Map<String, String> _flutterFiles = {
  'packages/flutter/lib/src/widgets/framework.dart':
      'abstract class Widget {\n  void build() {}\n}\n',
  'packages/flutter/lib/src/rendering/paragraph.dart':
      'class RenderParagraph extends RenderBox {}\n',
  'packages/flutter_test/lib/flutter_test.dart': 'class WidgetTester {}\n',
  'packages/flutter/pubspec.yaml': 'name: flutter\n',
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'grep_sdk_source', arguments: args);

Map<String, Object?> _payload(CallToolResult result) =>
    jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;

List<Map<String, Object?>> _matches(CallToolResult result) =>
    ((_payload(result)['matches'] as List<Object?>?) ?? const []).cast<Map<String, Object?>>();

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

  GrepSdkSourceHandler buildHandler({
    String? platformVersion,
    Map<String, String>? flutterEnvironment,
  }) => GrepSdkSourceHandler(
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

  // ─── Dart mode ──────────────────────────────────────────────────────────────

  group('dart mode', () {
    test('scoped scan restricts matches to the given library', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'library': 'core', 'version': '3.12.2', 'pattern': 'isEmpty'}),
      );

      expect(result.isError, isNull);
      final files = _matches(result).map((m) => m['file']).toSet();
      expect(files, equals({'lib/core/list.dart', 'lib/core/map.dart'}));
    });

    test('unscoped scan (no library) searches the whole dart: tree', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'version': '3.12.2', 'pattern': 'isEmpty'}),
      );

      final files = _matches(result).map((m) => m['file']).toSet();
      expect(files, equals({'lib/core/list.dart', 'lib/core/map.dart'}));
    });

    test('response echoes sdk, library, pattern, resolvedVersion', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'library': 'core', 'version': '3.12.2', 'pattern': 'isEmpty'}),
      );

      final payload = _payload(result);
      expect(payload['sdk'], equals('dart'));
      expect(payload['library'], equals('core'));
      expect(payload['pattern'], equals('isEmpty'));
      expect(payload['resolvedVersion'], equals('3.12.2'));
      expect(payload.containsKey('package'), isFalse);
    });

    test('rejects a library containing a path separator with INVALID_ARGUMENT', () async {
      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'library': 'core/nested', 'pattern': 'x'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });
  });

  // ─── Flutter mode ───────────────────────────────────────────────────────────

  group('flutter mode', () {
    test('scoped scan restricts matches to the given package', () async {
      stubSdkTarball(mockHttp, _flutterFiles, owner: 'flutter', repo: 'flutter', ref: '3.35.1');

      final result = await buildHandler().call(
        _request({
          'sdk': 'flutter',
          'package': 'flutter',
          'version': '3.35.1',
          'pattern': 'RenderParagraph',
        }),
      );

      expect(result.isError, isNull);
      final files = _matches(result).map((m) => m['file']).toSet();
      expect(files, equals({'packages/flutter/lib/src/rendering/paragraph.dart'}));
    });

    test('unscoped scan (no package) searches the whole flutter/flutter tree', () async {
      stubSdkTarball(mockHttp, _flutterFiles, owner: 'flutter', repo: 'flutter', ref: '3.35.1');

      final result = await buildHandler().call(
        _request({'sdk': 'flutter', 'version': '3.35.1', 'pattern': 'class'}),
      );

      final files = _matches(result).map((m) => m['file']).toSet();
      expect(
        files,
        equals({
          'packages/flutter/lib/src/widgets/framework.dart',
          'packages/flutter/lib/src/rendering/paragraph.dart',
          'packages/flutter_test/lib/flutter_test.dart',
        }),
      );
    });

    test('response echoes sdk, package, pattern', () async {
      stubSdkTarball(mockHttp, _flutterFiles, owner: 'flutter', repo: 'flutter', ref: '3.35.1');

      final result = await buildHandler().call(
        _request({
          'sdk': 'flutter',
          'package': 'flutter_test',
          'version': '3.35.1',
          'pattern': 'WidgetTester',
        }),
      );

      final payload = _payload(result);
      expect(payload['sdk'], equals('flutter'));
      expect(payload['package'], equals('flutter_test'));
      expect(payload.containsKey('library'), isFalse);
    });

    test('rejects a package containing a path separator with INVALID_ARGUMENT', () async {
      final result = await buildHandler().call(
        _request({'sdk': 'flutter', 'package': 'flutter/nested', 'pattern': 'x'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('returns SDK_NOT_DETECTED when no Flutter install is found', () async {
      final result = await buildHandler(flutterEnvironment: const {}).call(
        _request({'sdk': 'flutter', 'pattern': 'x'}),
      );

      expect(result.isError, isTrue);
      final error = _errorPayload(result);
      expect(error['code'], equals(DomainErrors.sdkNotDetected));
    });
  });

  // ─── Default .dart-only scope ───────────────────────────────────────────────

  group('default extension scope', () {
    test('excludes non-.dart files by default', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'version': '3.12.2', 'pattern': 'isEmpty'}),
      );

      final files = _matches(result).map((m) => m['file']! as String).toList();
      expect(files.any((f) => f.endsWith('.md')), isFalse);
    });

    test('fileExtension override widens scope to a non-.dart extension', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'version': '3.12.2',
          'pattern': 'isEmpty',
          'fileExtension': '.md',
        }),
      );

      final files = _matches(result).map((m) => m['file']).toList();
      expect(files, equals(['README.md']));
    });

    test('fileExtension override narrows within .dart files too', () async {
      stubSdkTarball(mockHttp, _flutterFiles, owner: 'flutter', repo: 'flutter', ref: '3.35.1');

      final result = await buildHandler().call(
        _request({
          'sdk': 'flutter',
          'version': '3.35.1',
          'pattern': 'flutter',
          'caseInsensitive': true,
          'fileExtension': '.yaml',
        }),
      );

      final files = _matches(result).map((m) => m['file']).toList();
      expect(files, equals(['packages/flutter/pubspec.yaml']));
    });
  });

  // ─── Regex / case-insensitivity / context lines ─────────────────────────────

  group('regex, case-insensitivity, and context', () {
    test('compiles pattern as RegExp when regex is true', () async {
      stubSdkTarball(mockHttp, {'sdk/lib/core/list.dart': 'int a1 = 1;\nString name = "x";\n'});

      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'version': '3.12.2',
          'pattern': r'^int \w+\d+ = \d+;$',
          'regex': true,
        }),
      );

      expect(_matches(result), hasLength(1));
    });

    test('invalid regex returns INVALID_ARGUMENT with the compiler message', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'version': '3.12.2',
          'pattern': '(unterminated',
          'regex': true,
        }),
      );

      expect(result.isError, isTrue);
      final error = _errorPayload(result);
      expect(error['code'], equals(DomainErrors.invalidArgument));
      expect(error['suggestion'], isNotEmpty);
    });

    test('caseInsensitive matches regardless of case', () async {
      stubSdkTarball(mockHttp, {'sdk/lib/core/list.dart': 'ISEMPTY\nisEmpty\n'});

      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'version': '3.12.2',
          'pattern': 'isEmpty',
          'caseInsensitive': true,
        }),
      );

      expect(_matches(result), hasLength(2));
    });

    test('symmetric contextLines surrounds the match', () async {
      stubSdkTarball(mockHttp, {'sdk/lib/core/list.dart': 'a\nb\nmatch\nc\nd\n'});

      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'version': '3.12.2',
          'pattern': 'match',
          'contextLines': 2,
        }),
      );

      final match = _matches(result).single;
      expect(match['contextBefore'], equals(['a', 'b']));
      expect(match['contextAfter'], equals(['c', 'd']));
    });
  });

  // ─── directory filter ───────────────────────────────────────────────────────

  group('directory filter', () {
    test('restricts the scan to files under the given directory', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'version': '3.12.2',
          'pattern': 'isEmpty',
          'directory': 'lib/core/',
        }),
      );

      final files = _matches(result).map((m) => m['file']).toSet();
      expect(files, equals({'lib/core/list.dart', 'lib/core/map.dart'}));
    });

    test('a full file path scopes the scan to that one file', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'version': '3.12.2',
          'pattern': 'isEmpty',
          'directory': 'lib/core/list.dart',
        }),
      );

      final files = _matches(result).map((m) => m['file']).toSet();
      expect(files, equals({'lib/core/list.dart'}));
    });
  });

  // ─── Match cap ───────────────────────────────────────────────────────────────

  group('match cap', () {
    test('caps results at 50 and sets hasMore', () async {
      final lines = List.generate(60, (i) => 'needle line $i').join('\n');
      stubSdkTarball(mockHttp, {'sdk/lib/core/list.dart': lines});

      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'version': '3.12.2', 'pattern': 'needle'}),
      );

      expect(_matches(result), hasLength(50));
      expect(_payload(result)['hasMore'], isTrue);
    });

    test('hasMore is false when matches are within the cap', () async {
      stubSdkTarball(mockHttp, {'sdk/lib/core/list.dart': 'needle\n'});

      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'version': '3.12.2', 'pattern': 'needle'}),
      );

      expect(_matches(result), hasLength(1));
      expect(_payload(result)['hasMore'], isFalse);
    });
  });

  // ─── Validation ──────────────────────────────────────────────────────────────

  group('validation', () {
    test('rejects sdk values other than dart/flutter with INVALID_ARGUMENT', () async {
      final result = await buildHandler().call(_request({'sdk': 'kotlin', 'pattern': 'x'}));

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('missing pattern returns INVALID_ARGUMENT', () async {
      final result = await buildHandler().call(_request({'sdk': 'dart', 'version': '3.12.2'}));

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });
  });

  // ─── Version resolution ──────────────────────────────────────────────────────

  group('version resolution', () {
    test('returns SDK_VERSION_NOT_FOUND for an unresolvable explicit version', () async {
      stubSdkTarball(mockHttp, _rawFiles, ref: '999.0.0', statusCode: 404);

      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'version': '999.0.0', 'pattern': 'x'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.sdkVersionNotFound));
    });

    test('auto-detects the ref from Platform.version when version is omitted', () async {
      stubSdkTarball(mockHttp, _rawFiles, ref: '3.9.0');

      final result = await buildHandler(
        platformVersion: '3.9.0 (stable) (...) on "linux_x64"',
      ).call(_request({'sdk': 'dart', 'pattern': 'isEmpty'}));

      expect(result.isError, isNull);
      expect(_payload(result)['resolvedVersion'], equals('3.9.0'));
    });
  });

  // ─── outputSchema conformance ────────────────────────────────────────────────

  group('outputSchema conformance', () {
    test('structuredContent conforms to the declared outputSchema', () async {
      stubSdkTarball(mockHttp, _rawFiles);

      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'version': '3.12.2',
          'pattern': 'isEmpty',
          'contextLines': 1,
        }),
      );

      expectConformsToOutputSchema(grepSdkSourceTool, result.structuredContent);
    });
  });
}
