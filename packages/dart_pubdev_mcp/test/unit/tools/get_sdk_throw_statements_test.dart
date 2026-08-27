/// Unit tests for [GetSdkThrowStatementsHandler].
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:dart_pubdev_mcp/src/analysis/ast_access.dart';
import 'package:dart_pubdev_mcp/src/cache/cache_registry.dart';
import 'package:dart_pubdev_mcp/src/data/domain_error.dart';
import 'package:dart_pubdev_mcp/src/tools/get_sdk_throw_statements.dart';
import 'package:dart_pubdev_mcp/src/tools/tool_definitions.dart' show getSdkThrowStatementsTool;
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';
import '../../support/pub_stubs.dart';
import '../../support/schema_conformance.dart';

// ─── Dart SDK source fixtures ─────────────────────────────────────────────────

/// A class with multiple methods that throw different exception types.
const _serviceSource = r'''
class UserService {
  UserService(String name) {
    if (name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Name cannot be empty');
    }
  }

  String getUser(String id) {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'ID is required');
    }
    return id;
  }

  void deleteUser(String id) {
    print('deleted $id');
  }
}
''';

/// Two top-level functions that throw, plus one that doesn't.
const _utilsSource = '''
void processData(List<int> data) {
  if (data.isEmpty) {
    throw StateError('Data list must not be empty');
  }
}

String noThrow() => 'hello';
''';

/// Two classes with the same name `Repo` in different files — only the
/// second contains `disconnect`.
const _repoASource = 'class Repo { void connect() {} }';
const _repoBSource = 'class Repo { void disconnect() { throw StateError("not connected"); } }';

/// A top-level function `log` declared in two different files — an
/// ambiguous method-only scan.
const _logASource = r'void log(String msg) { throw StateError("a: $msg"); }';
const _logBSource = 'void log(String msg) { throw ArgumentError(msg); }';

// ─── Helpers ──────────────────────────────────────────────────────────────────

CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'get_sdk_throw_statements', arguments: args);

Map<String, Object?> _payload(CallToolResult result) =>
    jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;

Map<String, Object?> _errorPayload(CallToolResult result) {
  final outer = _payload(result);
  final inner = outer['error'];
  if (inner is! Map<String, Object?>) throw StateError('No nested error object');
  return inner;
}

List<Map<String, Object?>> _records(CallToolResult result) =>
    ((_payload(result)['throws'] as List<Object?>?) ?? const []).cast<Map<String, Object?>>();

List<String> _candidates(Map<String, Object?> errorPayload) {
  final details = errorPayload['details'];
  if (details is! Map<String, Object?>) fail('expected details Map in error payload');
  final candidates = details['candidates'];
  if (candidates is! List<Object?>) fail('expected candidates List in details');
  return candidates.cast<String>();
}

void main() {
  late TestStack stack;
  late MockHttpClient mockHttp;
  late CacheRegistry registry;

  GetSdkThrowStatementsHandler buildHandler({
    String? platformVersion,
    Map<String, String>? flutterEnvironment,
  }) => GetSdkThrowStatementsHandler(
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

  // ─── argument validation ────────────────────────────────────────────────

  group('argument validation', () {
    test('rejects sdk values other than "dart"/"flutter" with INVALID_ARGUMENT', () async {
      final result = await buildHandler().call(
        _request({'sdk': 'kotlin', 'library': 'core', 'symbol': 'Foo'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('rejects a missing library (dart) with INVALID_ARGUMENT', () async {
      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'symbol': 'Foo'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('rejects a missing package (flutter) with INVALID_ARGUMENT', () async {
      final result = await buildHandler().call(
        _request({'sdk': 'flutter', 'symbol': 'Foo'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('returns INVALID_ARGUMENT when symbol is omitted', () async {
      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'library': 'core'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('treats an empty-string symbol as omitted', () async {
      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'library': 'core', 'symbol': ''}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });
  });

  // ─── Dart: class-only scan ──────────────────────────────────────────────

  group('dart — class-only scan', () {
    setUp(() {
      stubSdkTarball(mockHttp, {'sdk/lib/core/service.dart': _serviceSource});
    });

    test('returns every throw in the class', () async {
      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'symbol': 'UserService',
          'version': '3.12.2',
        }),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(2));
      final symbols = records.map((r) => (r['symbol'] as String?) ?? '').toSet();
      expect(symbols, containsAll(['UserService.new', 'UserService.getUser']));
      expect(records.every((r) => r.containsKey('thrownType')), isTrue);
      expect(records.every((r) => r['path'] == 'lib/core/service.dart'), isTrue);
      expect(records.every((r) => r['line'] is int), isTrue);
    });

    test('supports backwards-compatible class parameter', () async {
      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'class': 'UserService',
          'version': '3.12.2',
        }),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(2));
    });

    test('response carries sdk and library fields', () async {
      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'symbol': 'UserService',
          'version': '3.12.2',
        }),
      );

      final payload = _payload(result);
      expect(payload['sdk'], equals('dart'));
      expect(payload['library'], equals('core'));
      expect(payload.containsKey('package'), isFalse);
    });

    test('structuredContent conforms to the declared outputSchema', () async {
      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'symbol': 'UserService',
          'version': '3.12.2',
        }),
      );

      expectConformsToOutputSchema(getSdkThrowStatementsTool, result.structuredContent);
    });

    test('returns SYMBOL_NOT_FOUND for an unknown class', () async {
      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'symbol': 'NoSuchClass',
          'version': '3.12.2',
        }),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
    });

    test(
      'scan is scoped to the requested library — a class in another library is invisible',
      () async {
        stubSdkTarball(mockHttp, {
          'sdk/lib/core/service.dart': _serviceSource,
          'sdk/lib/async/other.dart': 'class Other { void m() { throw StateError("x"); } }',
        });

        final result = await buildHandler().call(
          _request({'sdk': 'dart', 'library': 'core', 'symbol': 'Other', 'version': '3.12.2'}),
        );

        expect(result.isError, isTrue);
        expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
      },
    );
  });

  // ─── Dart: class + method scan ──────────────────────────────────────────

  group('dart — class + method scan', () {
    setUp(() {
      stubSdkTarball(mockHttp, {'sdk/lib/core/service.dart': _serviceSource});
    });

    test('returns only throws from the specified method', () async {
      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'symbol': 'UserService.getUser',
          'version': '3.12.2',
        }),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(1));
      expect(records.first['path'], equals('lib/core/service.dart'));
      expect(records.first['line'], equals(10));
      expect(records.first['symbol'], equals('UserService.getUser'));
      expect(records.first['thrownType'], equals('ArgumentError'));
    });

    test('supports backwards-compatible class + method parameters', () async {
      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'class': 'UserService',
          'method': 'getUser',
          'version': '3.12.2',
        }),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(1));
      expect(records.first['symbol'], equals('UserService.getUser'));
      expect(records.first['thrownType'], equals('ArgumentError'));
    });

    test('resolves the unnamed constructor via "new"', () async {
      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'symbol': 'UserService.new',
          'version': '3.12.2',
        }),
      );

      expect(result.isError, isNull);
      expect(_records(result), hasLength(1));
    });

    test('returns SYMBOL_NOT_FOUND when method absent from class', () async {
      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'symbol': 'UserService.missing',
          'version': '3.12.2',
        }),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
    });

    test('finds method in second file when first has a homonymous class lacking it', () async {
      stubSdkTarball(mockHttp, {
        'sdk/lib/core/a.dart': _repoASource,
        'sdk/lib/core/b.dart': _repoBSource,
      });

      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'symbol': 'Repo.disconnect',
          'version': '3.12.2',
        }),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(1));
      expect(records.first['thrownType'], equals('StateError'));
    });
  });

  // ─── Dart: top-level function scan ──────────────────────────────────────

  group('dart — top-level function scan', () {
    test('returns throws for a unique top-level function match', () async {
      stubSdkTarball(mockHttp, {'sdk/lib/core/utils.dart': _utilsSource});

      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'library': 'core', 'symbol': 'processData', 'version': '3.12.2'}),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(1));
      expect(records.first['symbol'], equals('processData'));
      expect(records.first['thrownType'], equals('StateError'));
    });

    test('supports backwards-compatible method parameter for top-level function', () async {
      stubSdkTarball(mockHttp, {'sdk/lib/core/utils.dart': _utilsSource});

      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'library': 'core', 'method': 'processData', 'version': '3.12.2'}),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(1));
      expect(records.first['symbol'], equals('processData'));
    });

    test('function with no throws returns an empty array', () async {
      stubSdkTarball(mockHttp, {'sdk/lib/core/utils.dart': _utilsSource});

      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'library': 'core', 'symbol': 'noThrow', 'version': '3.12.2'}),
      );

      expect(result.isError, isNull);
      expect(_records(result), isEmpty);
    });

    test('returns SYMBOL_NOT_FOUND when no top-level function matches', () async {
      stubSdkTarball(mockHttp, {'sdk/lib/core/utils.dart': _utilsSource});

      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'library': 'core', 'symbol': 'doesNotExist', 'version': '3.12.2'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
    });

    test('returns AMBIGUOUS_SYMBOL when the function is declared in two files', () async {
      stubSdkTarball(mockHttp, {
        'sdk/lib/core/a.dart': _logASource,
        'sdk/lib/core/b.dart': _logBSource,
      });

      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'library': 'core', 'symbol': 'log', 'version': '3.12.2'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.ambiguousSymbol));
    });

    test('AMBIGUOUS_SYMBOL candidates are file paths, not qualified names', () async {
      stubSdkTarball(mockHttp, {
        'sdk/lib/core/a.dart': _logASource,
        'sdk/lib/core/b.dart': _logBSource,
      });

      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'library': 'core', 'symbol': 'log', 'version': '3.12.2'}),
      );

      final candidates = _candidates(_errorPayload(result));
      expect(candidates, containsAll(['lib/core/a.dart', 'lib/core/b.dart']));
    });

    test('top-level function scan never issues a dartdoc/API-index HTTP request', () async {
      stubSdkTarball(mockHttp, {'sdk/lib/core/utils.dart': _utilsSource});

      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'library': 'core', 'symbol': 'processData', 'version': '3.12.2'}),
      );

      expect(result.isError, isNull);
      verifyNever(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('/documentation/'))),
          headers: any(named: 'headers'),
        ),
      );
    });
  });

  // ─── Dart: version resolution ───────────────────────────────────────────

  group('dart — version resolution', () {
    test('auto-detects the ref from Platform.version when version is omitted', () async {
      stubSdkTarball(mockHttp, {'sdk/lib/core/service.dart': _serviceSource}, ref: '3.9.0');

      final result = await buildHandler(
        platformVersion: '3.9.0 (stable) (...) on "linux_x64"',
      ).call(_request({'sdk': 'dart', 'library': 'core', 'symbol': 'UserService'}));

      expect(result.isError, isNull);
      expect(_payload(result)['resolvedVersion'], equals('3.9.0'));
    });

    test('returns SDK_VERSION_NOT_FOUND for an unresolvable explicit version', () async {
      stubSdkTarball(
        mockHttp,
        {'sdk/lib/core/service.dart': _serviceSource},
        ref: '999.0.0',
        statusCode: 404,
      );

      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'symbol': 'UserService',
          'version': '999.0.0',
        }),
      );

      expect(result.isError, isTrue);
      final error = _errorPayload(result);
      expect(error['code'], equals(DomainErrors.sdkVersionNotFound));
      expect((error['details'] as Map<String, Object?>?)?['sdk'], equals('dart'));
    });
  });

  // ─── Flutter ─────────────────────────────────────────────────────────────

  group('flutter', () {
    test('class-only scan finds throws under packages/<package>/lib/', () async {
      stubSdkTarball(
        mockHttp,
        {'packages/flutter/lib/src/widgets/service.dart': _serviceSource},
        owner: 'flutter',
        repo: 'flutter',
        ref: '3.35.1',
      );

      final result = await buildHandler().call(
        _request({
          'sdk': 'flutter',
          'package': 'flutter',
          'symbol': 'UserService',
          'version': '3.35.1',
        }),
      );

      expect(result.isError, isNull);
      final payload = _payload(result);
      expect(payload['sdk'], equals('flutter'));
      expect(payload['package'], equals('flutter'));
      expect(payload.containsKey('library'), isFalse);
      expect(_records(result), hasLength(2));
    });

    test('top-level function scan resolves a unique match', () async {
      stubSdkTarball(
        mockHttp,
        {'packages/flutter/lib/src/widgets/utils.dart': _utilsSource},
        owner: 'flutter',
        repo: 'flutter',
        ref: '3.35.1',
      );

      final result = await buildHandler().call(
        _request({
          'sdk': 'flutter',
          'package': 'flutter',
          'symbol': 'processData',
          'version': '3.35.1',
        }),
      );

      expect(result.isError, isNull);
      expect(_records(result), hasLength(1));
    });

    test('returns SDK_NOT_DETECTED when no install is found and no version is given', () async {
      final result = await buildHandler(flutterEnvironment: const {}).call(
        _request({'sdk': 'flutter', 'package': 'flutter', 'symbol': 'Foo'}),
      );

      expect(result.isError, isTrue);
      final error = _errorPayload(result);
      expect(error['code'], equals(DomainErrors.sdkNotDetected));
      verifyNever(() => mockHttp.send(any()));
    });
  });

  // ─── caching ─────────────────────────────────────────────────────────────

  group('caching', () {
    test('does not issue a second tarball request within the TTL window', () async {
      stubSdkTarball(mockHttp, {'sdk/lib/core/service.dart': _serviceSource});
      final handler = buildHandler();

      await handler.call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'symbol': 'UserService',
          'version': '3.12.2',
        }),
      );
      await handler.call(
        _request({
          'sdk': 'dart',
          'library': 'core',
          'symbol': 'UserService.getUser',
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
