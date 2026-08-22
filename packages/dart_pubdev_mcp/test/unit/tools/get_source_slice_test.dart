/// Unit tests for [GetSourceSliceHandler].
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:dart_pubdev_mcp/src/analysis/ast_access.dart';
import 'package:dart_pubdev_mcp/src/cache/cache_registry.dart';
import 'package:dart_pubdev_mcp/src/data/domain_error.dart';
import 'package:dart_pubdev_mcp/src/tools/get_source_slice.dart';
import 'package:dart_pubdev_mcp/src/tools/version_resolver.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';
import '../../support/pub_stubs.dart';

// ─── Fixtures ─────────────────────────────────────────────────────────────────

/// A Dart source file with a class spanning lines 1–10 (trailing newline).
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

const Map<String, String> _files = {
  'lib/src/widget.dart': _widgetSource,
  'README.md': '# foo',
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'get_source_slice', arguments: args);

Map<String, Object?> _payload(CallToolResult result) =>
    jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;

Map<String, Object?> _errorPayload(CallToolResult result) {
  final outer = _payload(result);
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
  final loggedMessages = <(LoggingLevel, Object)>[];

  GetSourceSliceHandler buildHandler() => GetSourceSliceHandler(
    versionResolver: versionResolver,
    astAccess: AstAccess(sourceFiles: registry.sourceFiles, ast: registry.ast),
    log: (level, data) => loggedMessages.add((level, data)),
  );

  setUp(() {
    stack = TestStack();
    mockHttp = stack.http;
    versionResolver = VersionResolver(
      client: stack.client,
      log: (level, data) => loggedMessages.add((level, data)),
    );
    registry = stack.caches;
    loggedMessages.clear();
  });

  tearDown(() => stack.close());

  // ─── Line-range mode ───────────────────────────────────────────────────────

  group('line-range mode', () {
    test('returns exactly the requested inclusive line range', () async {
      stubTarball(mockHttp, _files);

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'version': '1.0.0',
          'file': 'lib/src/widget.dart',
          'lineStart': 6,
          'lineEnd': 9,
        }),
      );

      expect(result.isError, isNull);
      final payload = _payload(result);
      expect(payload['mode'], equals('line-range'));
      expect(payload['lineStart'], equals(6));
      expect(payload['lineEnd'], equals(9));
      expect(payload['truncated'], isFalse);
      expect(
        payload['content'],
        equals('  int compute(int x) {\n    final y = x * 2;\n    return y + id;\n  }'),
      );
    });

    test('returns the full file verbatim when both bounds are omitted', () async {
      stubTarball(mockHttp, _files);

      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0', 'file': 'lib/src/widget.dart'}),
      );

      final payload = _payload(result);
      expect(payload['content'], equals(_widgetSource));
      expect(payload['lineStart'], equals(1));
      expect(payload['lineEnd'], equals(10));
      expect(payload['truncated'], isFalse);
    });

    test('reads from lineStart to end when only lineStart is supplied', () async {
      stubTarball(mockHttp, _files);

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'version': '1.0.0',
          'file': 'lib/src/widget.dart',
          'lineStart': 9,
        }),
      );

      final payload = _payload(result);
      expect(payload['lineStart'], equals(9));
      expect(payload['lineEnd'], equals(10));
      expect(payload['content'], equals('  }\n}'));
    });

    test('clamps an out-of-range lineEnd to the last line', () async {
      stubTarball(mockHttp, _files);

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'version': '1.0.0',
          'file': 'lib/src/widget.dart',
          'lineStart': 10,
          'lineEnd': 999,
        }),
      );

      final payload = _payload(result);
      expect(payload['lineStart'], equals(10));
      expect(payload['lineEnd'], equals(10));
      expect(payload['content'], equals('}'));
    });
  });

  // ─── Symbol-bounded mode ───────────────────────────────────────────────────

  group('symbol-bounded mode', () {
    test('returns the full class body when no maxLines is supplied', () async {
      stubTarball(mockHttp, _files);

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'version': '1.0.0',
          'file': 'lib/src/widget.dart',
          'symbol': 'Widget',
        }),
      );

      final payload = _payload(result);
      expect(payload['mode'], equals('symbol'));
      expect(payload['symbol'], equals('Widget'));
      expect(payload['lineStart'], equals(1));
      expect(payload['lineEnd'], equals(10));
      expect(payload['truncated'], isFalse);
      expect(payload['content'], equals(_widgetSource.trimRight()));
    });

    test('supports symbolName fallback for backward compatibility', () async {
      stubTarball(mockHttp, _files);

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'version': '1.0.0',
          'file': 'lib/src/widget.dart',
          'symbolName': 'Widget',
        }),
      );

      final payload = _payload(result);
      expect(payload['mode'], equals('symbol'));
      expect(payload['symbol'], equals('Widget'));
      expect(payload['lineStart'], equals(1));
      expect(payload['lineEnd'], equals(10));
    });

    test('truncates to signature + omission comment + closing brace', () async {
      stubTarball(mockHttp, _files);

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'version': '1.0.0',
          'file': 'lib/src/widget.dart',
          'symbol': 'Widget',
          'maxLines': 3,
        }),
      );

      final payload = _payload(result);
      expect(payload['truncated'], isTrue);
      // lineEnd reports the symbol's true end line even when cut.
      expect(payload['lineEnd'], equals(10));
      expect(
        payload['content'],
        equals('class Widget {\n  // ... 8 lines omitted ...\n}'),
      );
    });

    test('locates a class member via "ClassName.member"', () async {
      stubTarball(mockHttp, _files);

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'version': '1.0.0',
          'file': 'lib/src/widget.dart',
          'symbol': 'Widget.compute',
        }),
      );

      final payload = _payload(result);
      expect(payload['lineStart'], equals(6));
      expect(payload['lineEnd'], equals(9));
      expect(payload['truncated'], isFalse);
      expect(
        payload['content'],
        equals('int compute(int x) {\n    final y = x * 2;\n    return y + id;\n  }'),
      );
    });

    test('truncates a member body when maxLines is exceeded', () async {
      stubTarball(mockHttp, _files);

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'version': '1.0.0',
          'file': 'lib/src/widget.dart',
          'symbol': 'Widget.compute',
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

    test('resolves the unnamed constructor via "new"', () async {
      stubTarball(mockHttp, _files);

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'version': '1.0.0',
          'file': 'lib/src/widget.dart',
          'symbol': 'Widget.new',
        }),
      );

      final payload = _payload(result);
      expect(payload['lineStart'], equals(4));
      expect(payload['content'], equals('Widget(this.id);'));
    });

    test('returns SYMBOL_NOT_FOUND for an unknown symbol', () async {
      stubTarball(mockHttp, _files);

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'version': '1.0.0',
          'file': 'lib/src/widget.dart',
          'symbol': 'DoesNotExist',
        }),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
    });
  });

  // ─── Version resolution ────────────────────────────────────────────────────

  group('version resolution', () {
    test('resolves the latest stable version when version is omitted', () async {
      stubPackageInfo(mockHttp, packageName: 'foo', version: '2.0.0');
      stubTarball(mockHttp, _files, version: '2.0.0');

      final result = await buildHandler().call(
        _request({'package': 'foo', 'file': 'lib/src/widget.dart', 'lineStart': 1, 'lineEnd': 1}),
      );

      expect(result.isError, isNull);
      expect(_payload(result)['resolvedVersion'], equals('2.0.0'));
    });

    test('surfaces PACKAGE_NOT_FOUND when resolution fails', () async {
      when(
        () => mockHttp.get(any(), headers: any(named: 'headers')),
      ).thenAnswer((_) async => notFound());

      final result = await buildHandler().call(
        _request({'package': 'missing', 'file': 'lib/src/widget.dart'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));
    });
  });

  // ─── SDK package guard ──────────────────────────────────────────────────────

  group('SDK package guard', () {
    test('rejects an SDK package name with no version supplied', () async {
      final result = await buildHandler().call(
        _request({'package': 'flutter', 'file': 'lib/src/widget.dart'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));
      verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
    });

    test('rejects an SDK package name even with an explicit version', () async {
      final result = await buildHandler().call(
        _request({'package': 'flutter', 'version': '3.35.0', 'file': 'lib/src/widget.dart'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));
      verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
    });
  });

  // ─── Argument validation ───────────────────────────────────────────────────

  group('argument validation', () {
    test('rejects a missing file with INVALID_ARGUMENT', () async {
      final result = await buildHandler().call(_request({'package': 'foo', 'version': '1.0.0'}));

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('rejects a path containing ".." with INVALID_ARGUMENT', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0', 'file': '../etc/passwd'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });
  });

  // ─── source_file_not_found ─────────────────────────────────────────────────

  group('source_file_not_found', () {
    test('returns SOURCE_FILE_NOT_FOUND for a missing path', () async {
      stubTarball(mockHttp, _files);

      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0', 'file': 'lib/src/missing.dart'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.sourceFileNotFound));
    });

    test('suggestion names a filename match when one exists', () async {
      stubTarball(mockHttp, {'lib/src/server/widget.dart': 'class Widget {}'});

      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0', 'file': 'lib/widget.dart'}),
      );

      expect(
        _errorPayload(result)['suggestion'] as String?,
        contains('lib/src/server/widget.dart'),
      );
    });
  });

  // ─── Caching ───────────────────────────────────────────────────────────────

  group('caching', () {
    test('does not issue a second tarball request within the TTL window', () async {
      stubTarball(mockHttp, _files);
      final handler = buildHandler();

      await handler.call(
        _request({'package': 'foo', 'version': '1.0.0', 'file': 'lib/src/widget.dart'}),
      );
      await handler.call(
        _request({
          'package': 'foo',
          'version': '1.0.0',
          'file': 'lib/src/widget.dart',
          'symbol': 'Widget',
        }),
      );

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
  });
}
