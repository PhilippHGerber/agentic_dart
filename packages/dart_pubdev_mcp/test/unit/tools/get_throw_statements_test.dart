/// Unit tests for [GetThrowStatementsHandler].
library;

import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:dart_pubdev_mcp/src/analysis/ast_access.dart';
import 'package:dart_pubdev_mcp/src/cache/cache_registry.dart';
import 'package:dart_pubdev_mcp/src/data/domain_error.dart';
import 'package:dart_pubdev_mcp/src/data/models.dart';
import 'package:dart_pubdev_mcp/src/tools/get_source_slice.dart';
import 'package:dart_pubdev_mcp/src/tools/get_throw_statements.dart';
import 'package:dart_pubdev_mcp/src/tools/tool_definitions.dart' show getThrowStatementsTool;
import 'package:dart_pubdev_mcp/src/tools/version_resolver.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';
import '../../support/pub_stubs.dart';
import '../../support/schema_conformance.dart';

// ─── Dart source fixtures ─────────────────────────────────────────────────────

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
    if (id.length > 100) {
      throw RangeError.value(id.length, 'id.length', 'ID too long');
    }
    return id;
  }

  void deleteUser(String id) {
    print('deleted $id');
  }
}
''';

/// A class whose methods have no throws — produces an empty result array.
const _noThrowSource = '''
class Calculator {
  int add(int a, int b) => a + b;
  int subtract(int a, int b) => a - b;
}
''';

/// A class with a throw inside a try/catch block.
const _tryCatchSource = r'''
class Parser {
  dynamic parse(String input) {
    try {
      return int.parse(input);
    } catch (e) {
      throw FormatException('Invalid input: $input');
    }
  }
}
''';

/// A class with a throw inside a closure — that throw must NOT be collected.
const _closureSource = '''
class Processor {
  void process(String input) {
    if (input.isEmpty) {
      throw ArgumentError('Input must not be empty');
    }
    final validator = () {
      throw StateError('closure throw — must be excluded');
    };
    validator();
  }
}
''';

/// A mixin with a throwing method.
const _mixinSource = '''
mixin Validator {
  void validate(String value) {
    if (value.isEmpty) {
      throw ArgumentError('Value must not be empty');
    }
  }
}
''';

/// An enum with a throwing getter.
const _enumSource = '''
enum Status {
  active,
  disabled;

  void assertActive() {
    if (this != Status.active) {
      throw StateError('Status is not active');
    }
  }
}
''';

/// Two top-level functions that throw.
const _utilsSource = '''
void processData(List<int> data) {
  if (data.isEmpty) {
    throw StateError('Data list must not be empty');
  }
}

int safeDivide(int a, int b) {
  if (b == 0) {
    throw ArgumentError.value(b, 'b', 'Divisor must not be zero');
  }
  return a ~/ b;
}
''';

/// A class with a constructor that throws.
const _constructorThrowSource = '''
class Config {
  Config(Map<String, Object?> json) {
    final name = json['name'];
    if (name == null) {
      throw ArgumentError.notNull('name');
    }
  }
}
''';

/// A class whose only `throw` is in a field initializer expression.
///
/// Field initializer throws are excluded from class-wide scans because there
/// is no member name to attach to the record.
const _fieldThrowSource = '''
class Config {
  static final instance = throw UnsupportedError('no instance');
  String get name => 'Config';
}
''';

/// A class that catches and rethrows an exception.
///
/// The `rethrow;` statement is a `RethrowExpression` AST node, distinct from
/// a `ThrowExpression`. The handler must report it with `thrownType == "rethrow"`.
const _rethrowSource = '''
class Wrapper {
  dynamic callApi(String url) {
    try {
      return _fetch(url);
    } catch (e) {
      rethrow;
    }
  }
}
''';

/// A class with a throwing getter and setter sharing the same name.
const _accessorThrowSource = '''
class Settings {
  int get value {
    throw StateError('getter failed');
  }

  set value(int next) {
    throw ArgumentError.value(next, 'next');
  }
}
''';

/// A class with a direct throw inside a large try block.
const _wideTryContextSource = '''
class Worker {
  void run(String input) {
    try {
      final trimmed = input.trim();
      final upper = trimmed.toUpperCase();
      final parts = upper.split(':');
      final joined = parts.join('-');
      print(joined);
      throw StateError('boom');
    } catch (e) {
      rethrow;
    }
  }
}
''';

/// Two classes with the same name `Repo` in different files.
///
/// Only the second file contains `disconnect` — a scan that stops at the first
/// homonymous class would incorrectly return `symbolNotFound`.
const _repoASource = 'class Repo { void connect() {} }';
const _repoBSource = 'class Repo { void disconnect() { throw StateError("not connected"); } }';

// ─── Helpers ──────────────────────────────────────────────────────────────────

DartdocSymbol _sym({
  required String name,
  required String qualifiedName,
  required String href,
  String type = 'function',
}) => DartdocSymbol(name: name, qualifiedName: qualifiedName, href: href, type: type, desc: '');

/// Maps a [DartdocSymbol.type] string back to its raw dartdoc `kind` int —
/// the inverse of [DartdocSymbol.fromJson]'s kind→type mapping — so tests can
/// serialise a hand-built symbol list into a synthetic `index.json` HTTP stub
/// body instead of pre-seeding the (now-private) apiIndex cache store.
int _kindFor(String type) => switch (type) {
  'class' => 3,
  'function' => 8,
  _ => throw ArgumentError('Add a case to _kindFor for type "$type".'),
};

/// Serialises [symbols] into a raw `index.json` HTTP response body.
String _indexJsonBody(List<DartdocSymbol> symbols) => jsonEncode([
  for (final s in symbols)
    {
      'name': s.name,
      'qualifiedName': s.qualifiedName,
      'href': s.href,
      'kind': _kindFor(s.type),
      'desc': s.desc,
    },
]);

CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'get_throw_statements', arguments: args);

Map<String, Object?> _errorPayload(CallToolResult result) {
  final outer = jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;
  final inner = outer['error'];
  if (inner is! Map<String, Object?>) throw StateError('No nested error object');
  return inner;
}

/// Extracts the `candidates` list from the `details` of an error payload.
List<String> _candidates(Map<String, Object?> errorPayload) {
  final details = errorPayload['details'];
  if (details is! Map<String, Object?>) fail('expected details Map in error payload');
  final candidates = details['candidates'];
  if (candidates is! List<Object?>) fail('expected candidates List in details');
  return candidates.cast<String>();
}

List<Map<String, Object?>> _records(CallToolResult result) {
  final json = jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;
  return ((json['throws'] as List<Object?>?) ?? const []).cast<Map<String, Object?>>();
}

/// Returns the `resolvedVersion` field of the success [result].
String? _resolvedVersion(CallToolResult result) {
  final json = jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;
  return json['resolvedVersion'] as String?;
}

int _lineCount(String text) => '\n'.allMatches(text).length + 1;

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late TestStack stack;
  late MockHttpClient mockHttp;
  late VersionResolver versionResolver;
  late CacheRegistry registry;

  GetThrowStatementsHandler buildHandler() => GetThrowStatementsHandler(
    versionResolver: versionResolver,
    astAccess: AstAccess(sourceFiles: registry.sourceFiles, ast: registry.ast),
    apiIndex: registry.apiIndex,
    log: (_, _) {},
  );

  setUp(() {
    stack = TestStack();
    mockHttp = stack.http;
    versionResolver = VersionResolver(client: stack.client, log: (_, _) {});
    registry = stack.caches;
  });

  tearDown(() => stack.close());

  // ─── invalid_input ────────────────────────────────────────────────────────

  group('invalid_input', () {
    test('returns invalid_input when symbol is omitted', () async {
      final result = await buildHandler().call(_request({'package': 'foo', 'version': '1.0.0'}));

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('returns invalid_input when symbol is empty string', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': '', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('invalid_input payload has message and suggestion', () async {
      final result = await buildHandler().call(_request({'package': 'foo', 'version': '1.0.0'}));

      expect(_errorPayload(result), contains('message'));
      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  // ─── class-only scan: all throws in class ────────────────────────────────

  group('class-only — entire class scan', () {
    setUp(() {
      stubTarball(mockHttp, {'lib/service.dart': _serviceSource});
    });

    test('returns non-empty array for class with throws', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'UserService', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, isNotEmpty);
    });

    test('all records contain file, symbol, thrownType, and context', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'UserService', 'version': '1.0.0'}),
      );

      final records = _records(result);
      for (final record in records) {
        expect(record, contains('file'));
        expect(record, contains('symbol'));
        expect(record, contains('thrownType'));
        expect(record, contains('context'));
      }
    });

    test('structuredContent conforms to the declared outputSchema', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'UserService', 'version': '1.0.0'}),
      );

      expectConformsToOutputSchema(getThrowStatementsTool, result.structuredContent);
    });

    test('all records have symbol prefixed with the scanned class name', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'UserService', 'version': '1.0.0'}),
      );

      final records = _records(result);
      for (final record in records) {
        expect((record['symbol']! as String).startsWith('UserService.'), isTrue);
      }
    });

    test('collects throws from constructor (tagged as "UserService.new")', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'UserService', 'version': '1.0.0'}),
      );

      final records = _records(result);
      final ctorRecord = records.firstWhere(
        (r) => r['symbol'] == 'UserService.new',
        orElse: () => <String, Object?>{},
      );
      expect(ctorRecord, isNotEmpty);
      expect(ctorRecord['thrownType'], equals('ArgumentError'));
    });

    test('collects throws from multiple methods independently', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'UserService', 'version': '1.0.0'}),
      );

      final records = _records(result);
      final symbols = records.map((r) => r['symbol']! as String).toSet();
      expect(symbols, contains('UserService.new'));
      expect(symbols, contains('UserService.getUser'));
    });

    test('returns empty array for class with no throws', () async {
      stubTarball(mockHttp, {'lib/calc.dart': _noThrowSource});

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'Calculator', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      expect(_records(result), isEmpty);
    });

    test('method with no throws does not appear in result', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'UserService', 'version': '1.0.0'}),
      );

      final records = _records(result);
      final symbols = records.map((r) => r['symbol']! as String).toSet();
      expect(symbols, isNot(contains('UserService.deleteUser')));
    });

    test('collects throws from mixin', () async {
      stubTarball(mockHttp, {'lib/mixin.dart': _mixinSource});

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'Validator', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(1));
      expect(records.first['symbol'], equals('Validator.validate'));
      expect(records.first['thrownType'], equals('ArgumentError'));
    });

    test('collects throws from enum method', () async {
      stubTarball(mockHttp, {'lib/status.dart': _enumSource});

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'Status', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(1));
      expect(records.first['symbol'], equals('Status.assertActive'));
      expect(records.first['thrownType'], equals('StateError'));
    });
  });

  // ─── class + method scan ─────────────────────────────────────────────────

  group('class + member — single method scan', () {
    setUp(() {
      stubTarball(mockHttp, {'lib/service.dart': _serviceSource});
    });

    test('returns only throws from the specified method', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'symbol': 'UserService.getUser',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(2));
      for (final record in records) {
        expect(record['symbol'], equals('UserService.getUser'));
      }
    });

    test('throws in other methods are excluded', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'symbol': 'UserService.getUser',
          'version': '1.0.0',
        }),
      );

      final records = _records(result);
      final symbols = records.map((r) => r['symbol']).toSet();
      expect(symbols, isNot(contains('UserService.new')));
    });

    test('records contain correct thrown types', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'symbol': 'UserService.getUser',
          'version': '1.0.0',
        }),
      );

      final types = _records(result).map((r) => r['thrownType']! as String).toSet();
      expect(types, containsAll(['ArgumentError', 'RangeError']));
    });

    test('context contains the surrounding if-statement text', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'symbol': 'UserService.getUser',
          'version': '1.0.0',
        }),
      );

      final contexts = _records(result).map((r) => r['context']! as String).toList();
      // At least one context should include the if-condition.
      expect(contexts.any((c) => c.contains('if')), isTrue);
    });

    test('returns empty array when method has no throws', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'symbol': 'UserService.deleteUser',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      expect(_records(result), isEmpty);
    });

    test('collects throws inside try/catch block', () async {
      stubTarball(mockHttp, {'lib/parser.dart': _tryCatchSource});

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'symbol': 'Parser.parse',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(1));
      expect(records.first['symbol'], equals('Parser.parse'));
      expect(records.first['thrownType'], equals('FormatException'));
    });

    test('excludes throws inside closures within the method', () async {
      stubTarball(mockHttp, {'lib/processor.dart': _closureSource});

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'symbol': 'Processor.process',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      // Only the direct throw should be captured; closure throw is excluded.
      expect(records, hasLength(1));
      expect(records.first['symbol'], equals('Processor.process'));
      expect(records.first['thrownType'], equals('ArgumentError'));
    });

    test('collects throw from constructor when symbol is "Config.new"', () async {
      stubTarball(mockHttp, {'lib/config.dart': _constructorThrowSource});

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'symbol': 'Config.new',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(1));
      expect(records.first['symbol'], equals('Config.new'));
      expect(records.first['thrownType'], equals('ArgumentError'));
    });

    test(
      'collects throws from both getter and setter when they share the requested name',
      () async {
        stubTarball(mockHttp, {'lib/settings.dart': _accessorThrowSource});

        final result = await buildHandler().call(
          _request({
            'package': 'foo',
            'symbol': 'Settings.value',
            'version': '1.0.0',
          }),
        );

        expect(result.isError, isNull);
        final records = _records(result);
        expect(records, hasLength(2));
        final types = records.map((r) => r['thrownType']! as String).toSet();
        expect(types, containsAll(['StateError', 'ArgumentError']));
        expect(records.map((r) => r['symbol']).toSet(), equals({'Settings.value'}));
      },
    );

    test('supports legacy class and method arguments', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'class': 'UserService',
          'method': 'getUser',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(2));
      for (final record in records) {
        expect(record['symbol'], equals('UserService.getUser'));
      }
    });
  });

  // ─── symbol_not_found ────────────────────────────────────────────────────

  group('symbol_not_found', () {
    setUp(() {
      stubTarball(mockHttp, {'lib/service.dart': _serviceSource});
    });

    test('returns symbol_not_found for bare unknown symbol', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'NonExistent', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
    });

    test('returns symbol_not_found for dotted unknown class', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'symbol': 'NonExistent.doSomething',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
    });

    test('symbol_not_found payload has message and suggestion', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'Ghost', 'version': '1.0.0'}),
      );

      expect(_errorPayload(result), contains('message'));
      expect(_errorPayload(result), contains('suggestion'));
    });

    test('returns symbol_not_found when method absent from class', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'symbol': 'UserService.nonExistentMethod',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
    });

    test('method_not_found payload has message and suggestion', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'symbol': 'UserService.missing',
          'version': '1.0.0',
        }),
      );

      expect(_errorPayload(result), contains('message'));
      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  // ─── top-level function — single match ───────────────────────────────────

  group('top-level function — single match', () {
    setUp(() {
      stubIndexJson(
        mockHttp,
        packageName: 'foo',
        version: '1.0.0',
        body: _indexJsonBody([
          _sym(name: 'processData', qualifiedName: 'foo.processData', href: 'foo/processData.html'),
        ]),
      );
      stubTarball(mockHttp, {'lib/foo.dart': _utilsSource});
    });

    test('returns throws array for top-level function', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'processData', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(1));
      expect(records.first['symbol'], equals('processData'));
    });

    test('result contains symbol field, not class/method/function fields', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'processData', 'version': '1.0.0'}),
      );

      final record = _records(result).first;
      expect(record, contains('symbol'));
      expect(record['symbol'], equals('processData'));
      expect(record, isNot(contains('class')));
      expect(record, isNot(contains('method')));
      expect(record, isNot(contains('function')));
    });

    test('thrownType is extracted correctly', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'processData', 'version': '1.0.0'}),
      );

      expect(_records(result).first['thrownType'], equals('StateError'));
    });

    test('function with no throws returns empty array', () async {
      stubIndexJson(
        mockHttp,
        packageName: 'bar',
        version: '1.0.0',
        body: _indexJsonBody([
          _sym(name: 'noThrow', qualifiedName: 'bar.noThrow', href: 'bar/noThrow.html'),
        ]),
      );
      stubTarball(mockHttp, {'lib/bar.dart': 'String noThrow() => "hello";'}, packageName: 'bar');

      final result = await buildHandler().call(
        _request({'package': 'bar', 'symbol': 'noThrow', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      expect(_records(result), isEmpty);
    });
  });

  // ─── top-level function — explicit version ───────────────────────────────

  group('top-level function — explicit version', () {
    test('uses explicit version in API index cache key', () async {
      stubIndexJson(
        mockHttp,
        packageName: 'foo',
        version: '2.0.0',
        body: _indexJsonBody([
          _sym(name: 'processData', qualifiedName: 'foo.processData', href: 'foo/processData.html'),
        ]),
      );
      stubTarball(mockHttp, {'lib/foo.dart': _utilsSource}, version: '2.0.0');

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'processData', 'version': '2.0.0'}),
      );

      expect(result.isError, isNull);
      expect(_records(result), isNotEmpty);
    });
  });

  // ─── ambiguous_symbol ────────────────────────────────────────────────────

  group('ambiguous_symbol', () {
    test('returns ambiguous_symbol when multiple functions match', () async {
      stubIndexJson(
        mockHttp,
        packageName: 'foo',
        version: '1.0.0',
        body: _indexJsonBody([
          _sym(name: 'log', qualifiedName: 'foo.log', href: 'foo/log.html'),
          _sym(name: 'log', qualifiedName: 'bar.log', href: 'bar/log.html'),
        ]),
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'log', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.ambiguousSymbol));
    });

    test('ambiguous_symbol payload includes candidates list in details', () async {
      stubIndexJson(
        mockHttp,
        packageName: 'foo',
        version: '1.0.0',
        body: _indexJsonBody([
          _sym(name: 'log', qualifiedName: 'foo.log', href: 'foo/log.html'),
          _sym(name: 'log', qualifiedName: 'bar.log', href: 'bar/log.html'),
        ]),
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'log', 'version': '1.0.0'}),
      );

      final candidates = _candidates(_errorPayload(result));
      expect(candidates, isA<List<String>>());
      expect(candidates, containsAll(['foo.log', 'bar.log']));
    });

    test('qualified retry resolves to correct function', () async {
      stubIndexJson(
        mockHttp,
        packageName: 'foo',
        version: '1.0.0',
        body: _indexJsonBody([
          _sym(name: 'log', qualifiedName: 'foo.log', href: 'foo/log.html'),
          _sym(name: 'log', qualifiedName: 'bar.log', href: 'bar/log.html'),
        ]),
      );
      stubTarball(mockHttp, {
        'lib/foo.dart': r'void log(String msg) { throw StateError("foo: $msg"); }',
        'lib/bar.dart': 'void log(String msg) { throw ArgumentError(msg); }',
      });

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'foo.log', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records.first['symbol'], equals('foo.log'));
      expect(records.first['thrownType'], equals('StateError'));
    });
  });

  // ─── method_not_found: top-level function ────────────────────────────────

  group('top-level function — method_not_found', () {
    test('returns method_not_found when function absent from API index', () async {
      stubIndexJson(
        mockHttp,
        packageName: 'foo',
        version: '1.0.0',
        body: _indexJsonBody([
          _sym(name: 'other', qualifiedName: 'foo.other', href: 'foo/other.html'),
        ]),
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'missing', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
    });

    test('non-function symbols excluded from top-level function search', () async {
      stubIndexJson(
        mockHttp,
        packageName: 'foo',
        version: '1.0.0',
        body: _indexJsonBody([
          _sym(
            name: 'processData',
            qualifiedName: 'foo.processData',
            href: 'foo/processData.html',
            type: 'class',
          ),
        ]),
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'processData', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
    });
  });

  // ─── package_not_found ───────────────────────────────────────────────────

  group('package_not_found', () {
    test('returns package_not_found when version resolution fails', () async {
      when(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('/api/packages/missing'))),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => http.Response('Not Found', 404));

      final result = await buildHandler().call(
        _request({'package': 'missing', 'symbol': 'Bar'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));
    });
  });

  // ─── response structure ──────────────────────────────────────────────────

  group('response structure', () {
    setUp(() {
      stubTarball(mockHttp, {'lib/service.dart': _serviceSource});
    });

    test('file field contains the relative source path', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'symbol': 'UserService.getUser',
          'version': '1.0.0',
        }),
      );

      final records = _records(result);
      for (final record in records) {
        expect(record['file'], equals('lib/service.dart'));
      }
    });

    test('package field contains the package name', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'symbol': 'UserService.getUser',
          'version': '1.0.0',
        }),
      );

      final json = jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;
      expect(json['package'], equals('foo'));
    });

    test('context is non-empty string', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'symbol': 'UserService.getUser',
          'version': '1.0.0',
        }),
      );

      for (final record in _records(result)) {
        expect(record['context'], isA<String>());
        expect(record['context']! as String, isNotEmpty);
      }
    });

    test('context contains the throw keyword', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'symbol': 'UserService.getUser',
          'version': '1.0.0',
        }),
      );

      for (final record in _records(result)) {
        expect(record['context']! as String, contains('throw'));
      }
    });
  });

  // ─── resolvedVersion ─────────────────────────────────────────────────────

  group('resolvedVersion — all scan shapes', () {
    test('class scan echoes the supplied version', () async {
      stubTarball(mockHttp, {'lib/service.dart': _serviceSource});

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'UserService', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      expect(_resolvedVersion(result), equals('1.0.0'));
    });

    test('class member scan echoes the supplied version', () async {
      stubTarball(mockHttp, {'lib/service.dart': _serviceSource});

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'symbol': 'UserService.getUser',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      expect(_resolvedVersion(result), equals('1.0.0'));
    });

    test('top-level function scan echoes the supplied version', () async {
      stubIndexJson(
        mockHttp,
        packageName: 'foo',
        version: '1.0.0',
        body: _indexJsonBody([
          _sym(name: 'processData', qualifiedName: 'foo.processData', href: 'foo/processData.html'),
        ]),
      );
      stubTarball(mockHttp, {'lib/foo.dart': _utilsSource});

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'processData', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      expect(_resolvedVersion(result), equals('1.0.0'));
    });
  });

  // ─── version-resolution success path ─────────────────────────────────────

  group('version omitted — resolves latest stable before scanning', () {
    test('class scan resolves version and echoes it in resolvedVersion', () async {
      stubPackageInfo(mockHttp, packageName: 'foo', version: '2.5.0');
      stubTarball(mockHttp, {'lib/service.dart': _serviceSource}, version: '2.5.0');

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'UserService'}),
      );

      expect(result.isError, isNull);
      expect(_resolvedVersion(result), equals('2.5.0'));
      expect(_records(result), isNotEmpty);
    });

    test('class member scan resolves version and echoes it in resolvedVersion', () async {
      stubPackageInfo(mockHttp, packageName: 'foo', version: '2.5.0');
      stubTarball(mockHttp, {'lib/service.dart': _serviceSource}, version: '2.5.0');

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'UserService.getUser'}),
      );

      expect(result.isError, isNull);
      expect(_resolvedVersion(result), equals('2.5.0'));
      final records = _records(result);
      expect(records, hasLength(2));
      for (final record in records) {
        expect(record['symbol'], equals('UserService.getUser'));
      }
    });
  });

  // ─── multi-file packages ─────────────────────────────────────────────────

  group('multi-file package', () {
    test('searches lib/ files before other directories', () async {
      stubTarball(mockHttp, {
        'test/service_test.dart': '// not a lib file',
        'lib/service.dart': _serviceSource,
      });

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'UserService', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
    });

    test('finds class declared in a non-first file', () async {
      stubTarball(mockHttp, {
        'lib/utils.dart': _utilsSource,
        'lib/service.dart': _serviceSource,
      });

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'UserService', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      expect(_records(result), isNotEmpty);
    });
  });

  // ─── AST cache behavior ──────────────────────────────────────────────────

  group('AST cache', () {
    test('caches the parsed AST for reuse across repeated calls for the same file', () async {
      stubTarball(mockHttp, {'lib/service.dart': _serviceSource});
      final handler = buildHandler();

      await handler.call(
        _request({'package': 'foo', 'symbol': 'UserService', 'version': '1.0.0'}),
      );

      expect(
        await registry.ast.peek((
          name: 'foo',
          version: '1.0.0',
          path: 'lib/service.dart',
          content: _serviceSource,
        )),
        isNotNull,
      );

      await handler.call(
        _request({
          'package': 'foo',
          'symbol': 'UserService.getUser',
          'version': '1.0.0',
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

    test('reuses the source file and AST warmed by get_source_slice', () async {
      stubTarball(mockHttp, {'lib/service.dart': _serviceSource});

      final sourceSliceHandler = GetSourceSliceHandler(
        versionResolver: versionResolver,
        astAccess: AstAccess(sourceFiles: registry.sourceFiles, ast: registry.ast),
        log: (_, _) {},
      );
      await sourceSliceHandler.call(
        CallToolRequest(
          name: 'get_source_slice',
          arguments: {
            'package': 'foo',
            'version': '1.0.0',
            'file': 'lib/service.dart',
            'symbol': 'UserService',
          },
        ),
      );

      await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'UserService', 'version': '1.0.0'}),
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

  // ─── source cache sharing ─────────────────────────────────────────────────

  group('source files cache sharing', () {
    test('warms the sourceFiles facade entry for (package, version)', () async {
      stubTarball(mockHttp, {'lib/service.dart': _serviceSource});

      await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'UserService', 'version': '1.0.0'}),
      );

      expect(await registry.sourceFiles.peek((name: 'foo', version: '1.0.0')), isNotNull);
    });
  });

  // ─── thrown type extraction ───────────────────────────────────────────────

  group('thrown type extraction', () {
    test('extracts type from implicit new syntax: throw SomeError(...)', () async {
      stubTarball(mockHttp, {
        'lib/foo.dart': 'class Foo { void m() { throw StateError("x"); } }',
      });

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'Foo.m', 'version': '1.0.0'}),
      );

      expect(_records(result).first['thrownType'], equals('StateError'));
    });

    test('extracts type from named factory: throw ArgumentError.value(...)', () async {
      stubTarball(mockHttp, {
        'lib/foo.dart': "class Foo { void m() { throw ArgumentError.value(0, 'x'); } }",
      });

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'Foo.m', 'version': '1.0.0'}),
      );

      expect(_records(result).first['thrownType'], equals('ArgumentError'));
    });

    test('extracts type from explicit new: throw new FormatException(...)', () async {
      stubTarball(mockHttp, {
        'lib/foo.dart': "class Foo { void m() { throw new FormatException('bad'); } }",
      });

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'Foo.m', 'version': '1.0.0'}),
      );

      expect(_records(result).first['thrownType'], equals('FormatException'));
    });

    test('extracts type from variable: throw someError', () async {
      stubTarball(mockHttp, {
        'lib/foo.dart': 'class Foo { void m(Exception e) { throw e; } }',
      });

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'Foo.m', 'version': '1.0.0'}),
      );

      expect(_records(result).first['thrownType'], equals('e'));
    });
  });

  // ─── context extraction ───────────────────────────────────────────────────

  group('context extraction', () {
    test('context for throw inside if contains the if statement', () async {
      stubTarball(mockHttp, {
        'lib/foo.dart': '''
class Foo {
  void m(String x) {
    if (x.isEmpty) {
      throw ArgumentError('empty');
    }
  }
}
''',
      });

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'Foo.m', 'version': '1.0.0'}),
      );

      final context = _records(result).first['context']! as String;
      expect(context, contains('if'));
      expect(context, contains('x.isEmpty'));
      expect(context, contains('throw ArgumentError'));
    });

    test('context for simple throw statement contains the throw', () async {
      stubTarball(mockHttp, {
        'lib/foo.dart': 'class Foo { void m() { throw UnimplementedError(); } }',
      });

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'Foo.m', 'version': '1.0.0'}),
      );

      final context = _records(result).first['context']! as String;
      expect(context, contains('throw UnimplementedError'));
    });

    test('context is bounded to a small line window around a direct throw', () async {
      stubTarball(mockHttp, {'lib/worker.dart': _wideTryContextSource});

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'Worker.run', 'version': '1.0.0'}),
      );

      final context = _records(result).first['context']! as String;
      expect(context, contains("throw StateError('boom')"));
      expect(_lineCount(context), lessThanOrEqualTo(3));
      expect(context, isNot(contains('final trimmed = input.trim();')));
    });
  });

  // ─── field initializer throws ─────────────────────────────────────────────

  group('field initializer throw', () {
    test('field initializer throw is excluded from class-wide scan results', () async {
      stubTarball(mockHttp, {'lib/config.dart': _fieldThrowSource});

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'Config', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      expect(_records(result), isEmpty);
    });

    test('getter method is still included when field initializer throw is present', () async {
      stubTarball(mockHttp, {
        'lib/config.dart': '''
class Config {
  static final bad = throw UnsupportedError("bad");
  void doWork() { throw StateError("not implemented"); }
}
''',
      });

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'Config', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(1));
      expect(records.first['symbol'], equals('Config.doWork'));
      expect(records.first['thrownType'], equals('StateError'));
    });
  });

  // ─── rethrow handling ─────────────────────────────────────────────────────

  group('rethrow handling', () {
    setUp(() {
      stubTarball(mockHttp, {'lib/wrapper.dart': _rethrowSource});
    });

    test('rethrow inside catch is included in results', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'symbol': 'Wrapper.callApi',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(1));
      expect(records.first['thrownType'], equals('rethrow'));
    });

    test('rethrow record includes context spanning the catch block', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'symbol': 'Wrapper.callApi',
          'version': '1.0.0',
        }),
      );

      final context = _records(result).first['context']! as String;
      expect(context, contains('rethrow'));
    });

    test('class-wide scan includes rethrow records', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'Wrapper', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      final types = _records(result).map((r) => r['thrownType']! as String).toSet();
      expect(types, contains('rethrow'));
    });

    test('rethrow record has symbol field set to the enclosing declaration', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'Wrapper', 'version': '1.0.0'}),
      );

      final records = _records(result);
      expect(records.first['symbol'], equals('Wrapper.callApi'));
    });

    test('explicit throw and rethrow in same method both appear in results', () async {
      stubTarball(mockHttp, {
        'lib/svc.dart': '''
class Svc {
  void run() {
    try {
      throw ArgumentError('bad');
    } catch (e) {
      rethrow;
    }
  }
}
''',
      });

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'symbol': 'Svc.run',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      final types = _records(result).map((r) => r['thrownType']! as String).toSet();
      expect(types, containsAll(['ArgumentError', 'rethrow']));
    });
  });

  // ─── homonymous class scanning ───────────────────────────────────────────

  group('homonymous class — single member scan', () {
    test(
      'finds method in second file when first file has same-named class without that method',
      () async {
        stubTarball(mockHttp, {
          'lib/a.dart': _repoASource,
          'lib/b.dart': _repoBSource,
        });

        final result = await buildHandler().call(
          _request({
            'package': 'foo',
            'symbol': 'Repo.disconnect',
            'version': '1.0.0',
          }),
        );

        expect(result.isError, isNull);
        final records = _records(result);
        expect(records, hasLength(1));
        expect(records.first['symbol'], equals('Repo.disconnect'));
        expect(records.first['thrownType'], equals('StateError'));
      },
    );

    test(
      'returns symbol_not_found when method is absent from ALL homonymous classes',
      () async {
        stubTarball(mockHttp, {
          'lib/a.dart': _repoASource,
          'lib/b.dart': _repoASource,
        });

        final result = await buildHandler().call(
          _request({
            'package': 'foo',
            'symbol': 'Repo.disconnect',
            'version': '1.0.0',
          }),
        );

        expect(result.isError, isTrue);
        expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
      },
    );

    test(
      'returns symbol_not_found when class is absent from all files',
      () async {
        stubTarball(mockHttp, {
          'lib/a.dart': 'class Other { void m() {} }',
        });

        final result = await buildHandler().call(
          _request({
            'package': 'foo',
            'symbol': 'Repo.disconnect',
            'version': '1.0.0',
          }),
        );

        expect(result.isError, isTrue);
        expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
      },
    );
  });

  group('homonymous class — class-wide scan', () {
    test('aggregates throws from both files when class name appears in two files', () async {
      stubTarball(mockHttp, {
        'lib/a.dart': 'class Repo { void connect() { throw StateError("a"); } }',
        'lib/b.dart': 'class Repo { void disconnect() { throw ArgumentError("b"); } }',
      });

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'Repo', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(2));
      final types = records.map((r) => r['thrownType']! as String).toSet();
      expect(types, containsAll(['StateError', 'ArgumentError']));
    });
  });

  // ─── concurrent in-flight cache poisoning ────────────────────────────────

  group('concurrent calls — API index', () {
    test(
      'two concurrent calls that share a cold API-index key both receive the error',
      () async {
        final completer = Completer<http.Response>();
        when(
          () => mockHttp.get(
            any(
              that: predicate<Uri>(
                (u) => u.toString().contains('/documentation/foo/1.0.0/index.json'),
              ),
            ),
            headers: any(named: 'headers'),
          ),
        ).thenAnswer((_) => completer.future);

        final handler = buildHandler();
        final f1 = handler.call(
          _request({'package': 'foo', 'symbol': 'log', 'version': '1.0.0'}),
        );
        final f2 = handler.call(
          _request({'package': 'foo', 'symbol': 'log', 'version': '1.0.0'}),
        );

        completer.complete(http.Response('', 429));

        final r1 = await f1;
        final r2 = await f2;

        expect(_errorPayload(r1)['code'], equals(DomainErrors.rateLimited));
        expect(_errorPayload(r2)['code'], equals(DomainErrors.rateLimited));
      },
    );
  });

  group('concurrent calls — source files', () {
    test(
      'two concurrent calls that share a cold source-file key both receive the error',
      () async {
        stubIndexJson(
          mockHttp,
          packageName: 'foo',
          version: '1.0.0',
          body: _indexJsonBody([
            _sym(name: 'log', qualifiedName: 'foo.log', href: 'foo/log.html'),
          ]),
        );

        final completer = Completer<http.StreamedResponse>();
        when(
          () => mockHttp.send(
            any(
              that: predicate<http.BaseRequest>(
                (r) => r.url.toString().contains('/archive.tar.gz'),
              ),
            ),
          ),
        ).thenAnswer((_) => completer.future);

        final handler = buildHandler();
        final f1 = handler.call(
          _request({'package': 'foo', 'symbol': 'log', 'version': '1.0.0'}),
        );
        final f2 = handler.call(
          _request({'package': 'foo', 'symbol': 'log', 'version': '1.0.0'}),
        );

        completer.complete(http.StreamedResponse(const Stream.empty(), 429));

        final r1 = await f1;
        final r2 = await f2;

        expect(_errorPayload(r1)['code'], equals(DomainErrors.rateLimited));
        expect(_errorPayload(r2)['code'], equals(DomainErrors.rateLimited));
      },
    );
  });

  // ─── API index transport errors ──────────────────────────────────────────

  group('top-level function — API index transport failure', () {
    test('404 from API index returns no_documentation', () async {
      when(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/foo/1.0.0/index.json'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => http.Response('Not Found', 404));

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'log', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.noDocumentation));
    });

    test('rate_limited from API index returns rate_limited, not no_documentation', () async {
      when(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/foo/1.0.0/index.json'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => http.Response('', 429));

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'log', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.rateLimited));
    });

    test('second call after rate_limited also returns rate_limited', () async {
      when(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/foo/1.0.0/index.json'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => http.Response('', 429));

      final handler = buildHandler();
      final first = await handler.call(
        _request({'package': 'foo', 'symbol': 'log', 'version': '1.0.0'}),
      );
      final second = await handler.call(
        _request({'package': 'foo', 'symbol': 'log', 'version': '1.0.0'}),
      );

      expect(_errorPayload(first)['code'], equals(DomainErrors.rateLimited));
      expect(_errorPayload(second)['code'], equals(DomainErrors.rateLimited));
    });
  });

  // ─── source-fetch transport errors ───────────────────────────────────────

  group('_loadSourceFiles — transient error propagation', () {
    setUp(() {
      stubIndexJson(
        mockHttp,
        packageName: 'foo',
        version: '1.0.0',
        body: _indexJsonBody([
          _sym(name: 'log', qualifiedName: 'foo.log', href: 'foo/log.html'),
        ]),
      );
    });

    test('request_timeout from tarball yields request_timeout', () async {
      when(
        () => mockHttp.send(
          any(
            that: predicate<http.BaseRequest>(
              (r) => r.url.toString().contains('/archive.tar.gz'),
            ),
          ),
        ),
      ).thenAnswer((_) async => throw TimeoutException('network timeout'));

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'log', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.requestTimeout));
    });

    test('rate_limited from tarball yields rate_limited', () async {
      when(
        () => mockHttp.send(
          any(
            that: predicate<http.BaseRequest>(
              (r) => r.url.toString().contains('/archive.tar.gz'),
            ),
          ),
        ),
      ).thenAnswer((_) async => http.StreamedResponse(const Stream.empty(), 429));

      final result = await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'log', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.rateLimited));
    });

    test('HTTP 404 from tarball yields package_not_found', () async {
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
        _request({'package': 'foo', 'symbol': 'log', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));
    });

    test('transient tarball failure does not leave a stale sourceFiles entry', () async {
      when(
        () => mockHttp.send(
          any(
            that: predicate<http.BaseRequest>(
              (r) => r.url.toString().contains('/archive.tar.gz'),
            ),
          ),
        ),
      ).thenAnswer((_) async => http.StreamedResponse(const Stream.empty(), 429));

      await buildHandler().call(
        _request({'package': 'foo', 'symbol': 'log', 'version': '1.0.0'}),
      );

      expect(await registry.sourceFiles.peek((name: 'foo', version: '1.0.0')), isNull);
    });
  });
}
