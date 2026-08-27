/// Unit tests for [GrepPackageSourceHandler].
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:dart_pubdev_mcp/src/cache/cache_registry.dart';
import 'package:dart_pubdev_mcp/src/data/domain_error.dart';
import 'package:dart_pubdev_mcp/src/tools/grep_package_source.dart';
import 'package:dart_pubdev_mcp/src/tools/tool_definitions.dart' show grepPackageSourceTool;
import 'package:dart_pubdev_mcp/src/tools/version_resolver.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';
import '../../support/pub_stubs.dart';
import '../../support/schema_conformance.dart';

// ─── Helpers ──────────────────────────────────────────────────────────────────

CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'grep_package_source', arguments: args);

Map<String, Object?> _payload(CallToolResult result) =>
    jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;

List<Map<String, Object?>> _matches(CallToolResult result) =>
    ((_payload(result)['matches'] as List<Object?>?) ?? const []).cast<Map<String, Object?>>();

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

  GrepPackageSourceHandler buildHandler() => GrepPackageSourceHandler(
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

  // ─── Literal match ─────────────────────────────────────────────────────────

  group('literal match', () {
    test('finds a plain substring match', () async {
      stubTarball(mockHttp, {
        'lib/src/client.dart': 'class Client {\n  void get() {\n    isEmpty();\n  }\n}\n',
      });

      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0', 'pattern': 'isEmpty'}),
      );

      expect(result.isError, isNull);
      final matches = _matches(result);
      expect(matches, hasLength(1));
      expect(matches.single['path'], equals('lib/src/client.dart'));
      expect(matches.single['line'], equals(3));
      expect(matches.single['matchedLine'], equals('    isEmpty();'));
    });

    test('parens are matched literally, not as regex metacharacters', () async {
      stubTarball(mockHttp, {
        'lib/src/client.dart': 'if (uri.path.isEmpty()) {\n  throw ArgumentError();\n}\n',
      });

      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0', 'pattern': 'isEmpty()'}),
      );

      expect(_matches(result), hasLength(1));
    });

    test('response echoes package and pattern', () async {
      stubTarball(mockHttp, {'lib/foo.dart': 'isEmpty'});

      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0', 'pattern': 'isEmpty'}),
      );

      final payload = _payload(result);
      expect(payload['package'], equals('foo'));
      expect(payload['pattern'], equals('isEmpty'));
      expect(payload['resolvedVersion'], equals('1.0.0'));
    });

    test('returns empty matches and hasMore false when nothing matches', () async {
      stubTarball(mockHttp, {'lib/foo.dart': 'void foo() {}'});

      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0', 'pattern': 'nonexistentPattern'}),
      );

      expect(_matches(result), isEmpty);
      expect(_payload(result)['hasMore'], isFalse);
    });
  });

  // ─── Regex match ───────────────────────────────────────────────────────────

  group('regex match', () {
    test('compiles pattern as a RegExp when regex is true', () async {
      stubTarball(mockHttp, {
        'lib/src/client.dart': 'int a1 = 1;\nint b22 = 2;\nString name = "x";\n',
      });

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'version': '1.0.0',
          'pattern': r'^int \w+\d+ = \d+;$',
          'regex': true,
        }),
      );

      expect(_matches(result), hasLength(2));
    });

    test('a literal-mode pattern with regex metacharacters does not match as regex', () async {
      stubTarball(mockHttp, {'lib/foo.dart': 'isEmpty()\nisEmptyX\n'});

      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0', 'pattern': 'isEmpty()'}),
      );

      // Literal mode: only the exact "isEmpty()" substring matches.
      expect(_matches(result), hasLength(1));
      expect(_matches(result).single['matchedLine'], equals('isEmpty()'));
    });

    test('invalid regex returns INVALID_ARGUMENT with the compiler message', () async {
      stubTarball(mockHttp, {'lib/foo.dart': 'void foo() {}'});

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'version': '1.0.0',
          'pattern': '(unterminated',
          'regex': true,
        }),
      );

      expect(result.isError, isTrue);
      final error = _errorPayload(result);
      expect(error['code'], equals(DomainErrors.invalidArgument));
      expect(error['suggestion'], isNotEmpty);
    });
  });

  // ─── Case sensitivity ──────────────────────────────────────────────────────

  group('case sensitivity', () {
    test('is case-sensitive by default', () async {
      stubTarball(mockHttp, {'lib/foo.dart': 'ISEMPTY\nisEmpty\n'});

      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0', 'pattern': 'isEmpty'}),
      );

      expect(_matches(result), hasLength(1));
      expect(_matches(result).single['matchedLine'], equals('isEmpty'));
    });

    test('caseInsensitive matches regardless of case (literal mode)', () async {
      stubTarball(mockHttp, {'lib/foo.dart': 'ISEMPTY\nisEmpty\n'});

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'version': '1.0.0',
          'pattern': 'isEmpty',
          'caseInsensitive': true,
        }),
      );

      expect(_matches(result), hasLength(2));
    });

    test('caseInsensitive applies to regex mode too', () async {
      stubTarball(mockHttp, {'lib/foo.dart': 'FOO\nfoo\n'});

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'version': '1.0.0',
          'pattern': r'^foo$',
          'regex': true,
          'caseInsensitive': true,
        }),
      );

      expect(_matches(result), hasLength(2));
    });
  });

  // ─── Context lines ─────────────────────────────────────────────────────────

  group('context lines', () {
    test('contextBefore/contextAfter are empty when contextLines is omitted', () async {
      stubTarball(mockHttp, {'lib/foo.dart': 'a\nb\nmatch\nc\nd\n'});

      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0', 'pattern': 'match'}),
      );

      final match = _matches(result).single;
      expect(match['contextBefore'], isEmpty);
      expect(match['contextAfter'], isEmpty);
    });

    test('symmetric contextLines surrounds the match', () async {
      stubTarball(mockHttp, {'lib/foo.dart': 'a\nb\nmatch\nc\nd\n'});

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'version': '1.0.0',
          'pattern': 'match',
          'contextLines': 2,
        }),
      );

      final match = _matches(result).single;
      expect(match['contextBefore'], equals(['a', 'b']));
      expect(match['contextAfter'], equals(['c', 'd']));
    });

    test('context is clamped at file boundaries', () async {
      stubTarball(mockHttp, {'lib/foo.dart': 'match\nb\n'});

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'version': '1.0.0',
          'pattern': 'match',
          'contextLines': 5,
        }),
      );

      final match = _matches(result).single;
      expect(match['contextBefore'], isEmpty);
      expect(match['contextAfter'], equals(['b']));
    });
  });

  // ─── Binary extension denylist ─────────────────────────────────────────────

  group('binary extension denylist', () {
    test('excludes denylisted extensions by default', () async {
      stubTarball(mockHttp, {
        'lib/foo.dart': 'needle',
        'assets/logo.png': 'needle',
      });

      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0', 'pattern': 'needle'}),
      );

      final paths = _matches(result).map((m) => m['path']).toList();
      expect(paths, equals(['lib/foo.dart']));
    });

    test('an explicit fileExtension override searches the denylisted extension', () async {
      stubTarball(mockHttp, {
        'lib/foo.dart': 'needle',
        'assets/logo.png': 'needle',
      });

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'version': '1.0.0',
          'pattern': 'needle',
          'fileExtension': '.png',
        }),
      );

      final paths = _matches(result).map((m) => m['path']).toList();
      expect(paths, equals(['assets/logo.png']));
    });
  });

  // ─── directory filter ──────────────────────────────────────────────────────

  group('directory filter', () {
    test('restricts the scan to files under the given directory', () async {
      stubTarball(mockHttp, {
        'lib/src/a.dart': 'needle',
        'test/b.dart': 'needle',
      });

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'version': '1.0.0',
          'pattern': 'needle',
          'directory': 'lib/src/',
        }),
      );

      final paths = _matches(result).map((m) => m['path']).toList();
      expect(paths, equals(['lib/src/a.dart']));
    });
  });

  // ─── Cap and hasMore ────────────────────────────────────────────────────────

  group('match cap', () {
    test('caps results at 50 and sets hasMore', () async {
      final lines = List.generate(60, (i) => 'needle line $i').join('\n');
      stubTarball(mockHttp, {'lib/foo.dart': lines});

      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0', 'pattern': 'needle'}),
      );

      expect(_matches(result), hasLength(50));
      expect(_payload(result)['hasMore'], isTrue);
    });

    test('hasMore is false when matches are within the cap', () async {
      final lines = List.generate(10, (i) => 'needle line $i').join('\n');
      stubTarball(mockHttp, {'lib/foo.dart': lines});

      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0', 'pattern': 'needle'}),
      );

      expect(_matches(result), hasLength(10));
      expect(_payload(result)['hasMore'], isFalse);
    });

    test('results are sorted by file then line number', () async {
      stubTarball(mockHttp, {
        'lib/z.dart': 'needle\n',
        'lib/a.dart': 'x\nneedle\n',
      });

      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0', 'pattern': 'needle'}),
      );

      final matches = _matches(result);
      expect(matches[0]['path'], equals('lib/a.dart'));
      expect(matches[1]['path'], equals('lib/z.dart'));
    });
  });

  // ─── Validation ─────────────────────────────────────────────────────────────

  group('validation', () {
    test('missing package returns INVALID_ARGUMENT', () async {
      final result = await buildHandler().call(_request({'pattern': 'needle'}));

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('missing pattern returns INVALID_ARGUMENT', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });
  });

  // ─── Package not found ──────────────────────────────────────────────────────

  group('package not found', () {
    test('returns package_not_found when the tarball 404s', () async {
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
        _request({'package': 'missing', 'version': '1.0.0', 'pattern': 'needle'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));
    });
  });

  // ─── SDK package guard ──────────────────────────────────────────────────────

  group('SDK package guard', () {
    test('rejects an SDK package name with no version supplied', () async {
      final result = await buildHandler().call(
        _request({'package': 'flutter', 'pattern': 'needle'}),
      );

      expect(result.isError, isTrue);
      final error = _errorPayload(result);
      expect(error['code'], equals(DomainErrors.packageNotFound));
      expect(error['suggestedNextStep'], isNotNull);

      verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
      verifyNever(() => mockHttp.send(any()));
    });

    test('rejects an SDK package name even with an explicit version', () async {
      final result = await buildHandler().call(
        _request({'package': 'flutter', 'version': '3.35.0', 'pattern': 'needle'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));

      verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
      verifyNever(() => mockHttp.send(any()));
    });
  });

  // ─── outputSchema conformance ──────────────────────────────────────────────

  group('outputSchema conformance', () {
    test('structuredContent conforms to the declared outputSchema', () async {
      stubTarball(mockHttp, {'lib/foo.dart': 'a\nneedle\nb\n'});

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'version': '1.0.0',
          'pattern': 'needle',
          'contextLines': 1,
        }),
      );

      expectConformsToOutputSchema(grepPackageSourceTool, result.structuredContent);
    });
  });
}
