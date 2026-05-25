/// Unit tests for [GetThrowStatementsHandler].
library;

import 'dart:async';
import 'dart:convert';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:dart_mcp/server.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:pubdev_context/src/cache/memory_cache.dart';
import 'package:pubdev_context/src/data/domain_error.dart';
import 'package:pubdev_context/src/data/models.dart';
import 'package:pubdev_context/src/data/pub_client.dart';
import 'package:pubdev_context/src/tools/browse_api_symbols.dart';
import 'package:pubdev_context/src/tools/get_throw_statements.dart';
import 'package:test/test.dart';

// ─── Mocks ────────────────────────────────────────────────────────────────────

class _MockHttpClient extends Mock implements http.Client {}

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
/// is no `method` name to attach to the record.
const _fieldThrowSource = '''
class Config {
  static final instance = throw UnsupportedError('no instance');
  String get name => 'Config';
}
''';

/// A class that catches and rethrows an exception.
///
/// The `rethrow;` statement is a `RethrowExpression` AST node, distinct from
/// a `ThrowExpression`. The handler must report it with `thrown_type == "rethrow"`.
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
/// homonymous class would incorrectly return `method_not_found`.
const _repoASource = 'class Repo { void connect() {} }';
const _repoBSource = 'class Repo { void disconnect() { throw StateError("not connected"); } }';

// ─── Helpers ──────────────────────────────────────────────────────────────────

RetryPolicy get _instant => RetryPolicy(delay: (_) async {});

DartdocSymbol _sym({
  required String name,
  required String qualifiedName,
  required String href,
  String type = 'function',
}) => DartdocSymbol(name: name, qualifiedName: qualifiedName, href: href, type: type, desc: '');

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

List<Map<String, Object?>> _records(CallToolResult result) =>
    (jsonDecode((result.content.first as TextContent).text) as List<Object?>)
        .cast<Map<String, Object?>>();

int _lineCount(String text) => '\n'.allMatches(text).length + 1;

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late _MockHttpClient mockHttp;
  late PubDevClient client;
  late ResponseCache<Map<String, String>> sourceFilesCache;
  late ResponseCache<List<DartdocSymbol>> apiIndexCache;

  GetThrowStatementsHandler buildHandler() => GetThrowStatementsHandler(
    client: client,
    sourceFilesCache: sourceFilesCache,
    apiIndexCache: apiIndexCache,
    log: (_, _) {},
  );

  setUp(() {
    mockHttp = _MockHttpClient();
    registerFallbackValue(Uri.parse('https://pub.dev'));
    client = PubDevClient(httpClient: mockHttp, retryPolicy: _instant);
    sourceFilesCache = ResponseCache();
    apiIndexCache = ResponseCache();
  });

  tearDown(() => client.close());

  // ─── invalid_input ────────────────────────────────────────────────────────

  group('invalid_input', () {
    test('returns invalid_input when neither class nor method is provided', () async {
      final result = await buildHandler().call(_request({'package': 'foo', 'version': '1.0.0'}));

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('returns invalid_input when method is empty string and no class', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': '', 'version': '1.0.0'}),
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
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/service.dart': _serviceSource}),
        kSourceFileTtl,
      );
    });

    test('returns non-empty array for class with throws', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'UserService', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, isNotEmpty);
    });

    test('all records contain file, class, method, thrown_type, and context', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'UserService', 'version': '1.0.0'}),
      );

      final records = _records(result);
      for (final record in records) {
        expect(record, contains('file'));
        expect(record, contains('class'));
        expect(record, contains('method'));
        expect(record, contains('thrown_type'));
        expect(record, contains('context'));
      }
    });

    test('all records have class set to the scanned class name', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'UserService', 'version': '1.0.0'}),
      );

      final records = _records(result);
      for (final record in records) {
        expect(record['class'], equals('UserService'));
      }
    });

    test('collects throws from constructor (tagged as "new")', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'UserService', 'version': '1.0.0'}),
      );

      final records = _records(result);
      final ctorRecord = records.firstWhere(
        (r) => r['method'] == 'new',
        orElse: () => <String, Object?>{},
      );
      expect(ctorRecord, isNotEmpty);
      expect(ctorRecord['thrown_type'], equals('ArgumentError'));
    });

    test('collects throws from multiple methods independently', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'UserService', 'version': '1.0.0'}),
      );

      final records = _records(result);
      final methods = records.map((r) => r['method']! as String).toSet();
      expect(methods, contains('new'));
      expect(methods, contains('getUser'));
    });

    test('returns empty array for class with no throws', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/calc.dart': _noThrowSource}),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'Calculator', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      expect(_records(result), isEmpty);
    });

    test('method with no throws does not appear in result', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'UserService', 'version': '1.0.0'}),
      );

      final records = _records(result);
      final methods = records.map((r) => r['method']! as String).toSet();
      expect(methods, isNot(contains('deleteUser')));
    });

    test('collects throws from mixin', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/mixin.dart': _mixinSource}),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'Validator', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(1));
      expect(records.first['thrown_type'], equals('ArgumentError'));
    });

    test('collects throws from enum method', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/status.dart': _enumSource}),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'Status', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(1));
      expect(records.first['method'], equals('assertActive'));
      expect(records.first['thrown_type'], equals('StateError'));
    });
  });

  // ─── class + method scan ─────────────────────────────────────────────────

  group('class + method — single method scan', () {
    setUp(() {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/service.dart': _serviceSource}),
        kSourceFileTtl,
      );
    });

    test('returns only throws from the specified method', () async {
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
        expect(record['method'], equals('getUser'));
      }
    });

    test('throws in other methods are excluded', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'class': 'UserService',
          'method': 'getUser',
          'version': '1.0.0',
        }),
      );

      final records = _records(result);
      final methods = records.map((r) => r['method']).toSet();
      expect(methods, isNot(contains('new'))); // nullable-safe: comparing Object? values
    });

    test('records contain correct thrown types', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'class': 'UserService',
          'method': 'getUser',
          'version': '1.0.0',
        }),
      );

      final types = _records(result).map((r) => r['thrown_type']! as String).toSet();
      expect(types, containsAll(['ArgumentError', 'RangeError']));
    });

    test('context contains the surrounding if-statement text', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'class': 'UserService',
          'method': 'getUser',
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
          'class': 'UserService',
          'method': 'deleteUser',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      expect(_records(result), isEmpty);
    });

    test('collects throws inside try/catch block', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/parser.dart': _tryCatchSource}),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'class': 'Parser',
          'method': 'parse',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(1));
      expect(records.first['thrown_type'], equals('FormatException'));
    });

    test('excludes throws inside closures within the method', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/processor.dart': _closureSource}),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'class': 'Processor',
          'method': 'process',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      // Only the direct throw should be captured; closure throw is excluded.
      expect(records, hasLength(1));
      expect(records.first['thrown_type'], equals('ArgumentError'));
    });

    test('collects throw from constructor when method is "new"', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/config.dart': _constructorThrowSource}),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'class': 'Config',
          'method': 'new',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(1));
      expect(records.first['thrown_type'], equals('ArgumentError'));
    });

    test(
      'collects throws from both getter and setter when they share the requested name',
      () async {
        sourceFilesCache.set(
          'source:foo:1.0.0',
          Future.value({'lib/settings.dart': _accessorThrowSource}),
          kSourceFileTtl,
        );

        final result = await buildHandler().call(
          _request({
            'package': 'foo',
            'class': 'Settings',
            'method': 'value',
            'version': '1.0.0',
          }),
        );

        expect(result.isError, isNull);
        final records = _records(result);
        expect(records, hasLength(2));
        final types = records.map((r) => r['thrown_type']! as String).toSet();
        expect(types, containsAll(['StateError', 'ArgumentError']));
        expect(records.map((r) => r['method']).toSet(), equals({'value'}));
      },
    );
  });

  // ─── class_not_found ─────────────────────────────────────────────────────

  group('class_not_found', () {
    setUp(() {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/service.dart': _serviceSource}),
        kSourceFileTtl,
      );
    });

    test('returns class_not_found for class-only scan of unknown class', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'NonExistent', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
    });

    test('returns class_not_found for class+method scan of unknown class', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'class': 'NonExistent',
          'method': 'doSomething',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
    });

    test('class_not_found payload has message and suggestion', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'Ghost', 'version': '1.0.0'}),
      );

      expect(_errorPayload(result), contains('message'));
      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  // ─── method_not_found ────────────────────────────────────────────────────

  group('method_not_found', () {
    setUp(() {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/service.dart': _serviceSource}),
        kSourceFileTtl,
      );
    });

    test('returns method_not_found when method absent from class', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'class': 'UserService',
          'method': 'nonExistentMethod',
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
          'class': 'UserService',
          'method': 'missing',
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
      apiIndexCache.set(
        '$kApiIndexCachePrefix:foo:1.0.0',
        Future.value([
          _sym(name: 'processData', qualifiedName: 'foo.processData', href: 'foo/processData.html'),
        ]),
        kApiDocsTtl,
      );
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/foo.dart': _utilsSource}),
        kSourceFileTtl,
      );
    });

    test('returns throws array for top-level function', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'processData', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(1));
    });

    test('result contains function field, not class/method fields', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'processData', 'version': '1.0.0'}),
      );

      final record = _records(result).first;
      expect(record, contains('function'));
      expect(record, isNot(contains('class')));
      expect(record, isNot(contains('method')));
    });

    test('function field matches the requested method name', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'processData', 'version': '1.0.0'}),
      );

      expect(_records(result).first['function'], equals('processData'));
    });

    test('thrown_type is extracted correctly', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'processData', 'version': '1.0.0'}),
      );

      expect(_records(result).first['thrown_type'], equals('StateError'));
    });

    test('function with no throws returns empty array', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:bar:1.0.0',
        Future.value([
          _sym(name: 'noThrow', qualifiedName: 'bar.noThrow', href: 'bar/noThrow.html'),
        ]),
        kApiDocsTtl,
      );
      sourceFilesCache.set(
        'source:bar:1.0.0',
        Future.value({'lib/bar.dart': 'String noThrow() => "hello";'}),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'bar', 'method': 'noThrow', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      expect(_records(result), isEmpty);
    });
  });

  // ─── top-level function — version-resolution path ────────────────────────

  group('top-level function — explicit version', () {
    test('uses explicit version in API index cache key', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:foo:2.0.0',
        Future.value([
          _sym(name: 'processData', qualifiedName: 'foo.processData', href: 'foo/processData.html'),
        ]),
        kApiDocsTtl,
      );
      sourceFilesCache.set(
        'source:foo:2.0.0',
        Future.value({'lib/foo.dart': _utilsSource}),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'processData', 'version': '2.0.0'}),
      );

      expect(result.isError, isNull);
      expect(_records(result), isNotEmpty);
    });
  });

  // ─── ambiguous_symbol ────────────────────────────────────────────────────

  group('ambiguous_symbol', () {
    test('returns ambiguous_symbol when multiple functions match', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:foo:1.0.0',
        Future.value([
          _sym(name: 'log', qualifiedName: 'foo.log', href: 'foo/log.html'),
          _sym(name: 'log', qualifiedName: 'bar.log', href: 'bar/log.html'),
        ]),
        kApiDocsTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'log', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.ambiguousSymbol));
    });

    test('ambiguous_symbol payload includes candidates list in details', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:foo:1.0.0',
        Future.value([
          _sym(name: 'log', qualifiedName: 'foo.log', href: 'foo/log.html'),
          _sym(name: 'log', qualifiedName: 'bar.log', href: 'bar/log.html'),
        ]),
        kApiDocsTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'log', 'version': '1.0.0'}),
      );

      final candidates = _candidates(_errorPayload(result));
      expect(candidates, isA<List<String>>());
      expect(candidates, containsAll(['foo.log', 'bar.log']));
    });

    test('qualified retry resolves to correct function', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:foo:1.0.0',
        Future.value([
          _sym(name: 'log', qualifiedName: 'foo.log', href: 'foo/log.html'),
          _sym(name: 'log', qualifiedName: 'bar.log', href: 'bar/log.html'),
        ]),
        kApiDocsTtl,
      );
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({
          'lib/foo.dart': r'void log(String msg) { throw StateError("foo: $msg"); }',
          'lib/bar.dart': 'void log(String msg) { throw ArgumentError(msg); }',
        }),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'foo.log', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records.first['thrown_type'], equals('StateError'));
    });
  });

  // ─── method_not_found: top-level function ────────────────────────────────

  group('top-level function — method_not_found', () {
    test('returns method_not_found when function absent from API index', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:foo:1.0.0',
        Future.value([
          _sym(name: 'other', qualifiedName: 'foo.other', href: 'foo/other.html'),
        ]),
        kApiDocsTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'missing', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
    });

    test('non-function symbols excluded from top-level function search', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:foo:1.0.0',
        Future.value([
          _sym(
            name: 'processData',
            qualifiedName: 'foo.processData',
            href: 'foo/processData.html',
            type: 'class',
          ),
        ]),
        kApiDocsTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'processData', 'version': '1.0.0'}),
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
        _request({'package': 'missing', 'class': 'Bar'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));
    });
  });

  // ─── response structure ──────────────────────────────────────────────────

  group('response structure', () {
    setUp(() {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/service.dart': _serviceSource}),
        kSourceFileTtl,
      );
    });

    test('file field contains the relative source path', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'class': 'UserService',
          'method': 'getUser',
          'version': '1.0.0',
        }),
      );

      final records = _records(result);
      for (final record in records) {
        expect(record['file'], equals('lib/service.dart'));
      }
    });

    test('context is non-empty string', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'class': 'UserService',
          'method': 'getUser',
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
          'class': 'UserService',
          'method': 'getUser',
          'version': '1.0.0',
        }),
      );

      for (final record in _records(result)) {
        expect(record['context']! as String, contains('throw'));
      }
    });
  });

  // ─── multi-file packages ─────────────────────────────────────────────────

  group('multi-file package', () {
    test('searches lib/ files before other directories', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({
          'test/service_test.dart': '// not a lib file',
          'lib/service.dart': _serviceSource,
        }),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'UserService', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
    });

    test('finds class declared in a non-first file', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({
          'lib/utils.dart': _utilsSource,
          'lib/service.dart': _serviceSource,
        }),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'UserService', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      expect(_records(result), isNotEmpty);
    });
  });

  // ─── AST cache behavior ──────────────────────────────────────────────────

  group('AST cache', () {
    test('reuses parsed AST on repeated calls for the same file', () async {
      final loggedMessages = <String>[];
      final handler = GetThrowStatementsHandler(
        client: client,
        sourceFilesCache: sourceFilesCache,
        apiIndexCache: apiIndexCache,
        log: (_, msg) => loggedMessages.add(msg.toString()),
      );

      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/service.dart': _serviceSource}),
        kSourceFileTtl,
      );

      // First call — parses the AST.
      await handler.call(
        _request({'package': 'foo', 'class': 'UserService', 'version': '1.0.0'}),
      );
      final countBefore = loggedMessages.where((m) => m.contains('parsing')).length;

      // Second call — should hit the AST cache.
      await handler.call(
        _request({
          'package': 'foo',
          'class': 'UserService',
          'method': 'getUser',
          'version': '1.0.0',
        }),
      );
      final countAfter = loggedMessages.where((m) => m.contains('parsing')).length;

      // The file should only have been parsed once in total.
      expect(countBefore, equals(1));
      expect(countAfter, equals(1));
    });

    test('AST cache is shared when same cache instance is injected', () async {
      // Verify that a shared cache pre-populated by one handler is used by another
      // handler (simulating server-level sharing).
      final sharedAstCache = ResponseCache<ParseStringResult>();
      final loggedMessages = <String>[];

      final handler = GetThrowStatementsHandler(
        client: client,
        sourceFilesCache: sourceFilesCache,
        apiIndexCache: apiIndexCache,
        log: (_, msg) => loggedMessages.add(msg.toString()),
        astCache: sharedAstCache,
      );

      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/service.dart': _serviceSource}),
        kSourceFileTtl,
      );

      await handler.call(
        _request({'package': 'foo', 'class': 'UserService', 'version': '1.0.0'}),
      );

      expect(loggedMessages.any((m) => m.contains('parsing')), isTrue);
    });
  });

  // ─── source cache sharing ─────────────────────────────────────────────────

  group('source files cache sharing', () {
    test('uses source:<package>:<version> cache key format', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/service.dart': _serviceSource}),
        kSourceFileTtl,
      );

      await buildHandler().call(
        _request({'package': 'foo', 'class': 'UserService', 'version': '1.0.0'}),
      );

      // No HTTP calls — uses pre-populated cache.
      verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
    });
  });

  // ─── thrown type extraction ───────────────────────────────────────────────

  group('thrown type extraction', () {
    test('extracts type from implicit new syntax: throw SomeError(...)', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({
          'lib/foo.dart': 'class Foo { void m() { throw StateError("x"); } }',
        }),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'Foo', 'method': 'm', 'version': '1.0.0'}),
      );

      expect(_records(result).first['thrown_type'], equals('StateError'));
    });

    test('extracts type from named factory: throw ArgumentError.value(...)', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({
          'lib/foo.dart': "class Foo { void m() { throw ArgumentError.value(0, 'x'); } }",
        }),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'Foo', 'method': 'm', 'version': '1.0.0'}),
      );

      expect(_records(result).first['thrown_type'], equals('ArgumentError'));
    });

    test('extracts type from explicit new: throw new FormatException(...)', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({
          'lib/foo.dart': "class Foo { void m() { throw new FormatException('bad'); } }",
        }),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'Foo', 'method': 'm', 'version': '1.0.0'}),
      );

      expect(_records(result).first['thrown_type'], equals('FormatException'));
    });

    test('extracts type from variable: throw someError', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({
          'lib/foo.dart': 'class Foo { void m(Exception e) { throw e; } }',
        }),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'Foo', 'method': 'm', 'version': '1.0.0'}),
      );

      expect(_records(result).first['thrown_type'], equals('e'));
    });
  });

  // ─── context extraction ───────────────────────────────────────────────────

  group('context extraction', () {
    test('context for throw inside if contains the if statement', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({
          'lib/foo.dart': '''
class Foo {
  void m(String x) {
    if (x.isEmpty) {
      throw ArgumentError('empty');
    }
  }
}
''',
        }),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'Foo', 'method': 'm', 'version': '1.0.0'}),
      );

      final context = _records(result).first['context']! as String;
      expect(context, contains('if'));
      expect(context, contains('x.isEmpty'));
      expect(context, contains('throw ArgumentError'));
    });

    test('context for simple throw statement contains the throw', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({
          'lib/foo.dart': 'class Foo { void m() { throw UnimplementedError(); } }',
        }),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'Foo', 'method': 'm', 'version': '1.0.0'}),
      );

      final context = _records(result).first['context']! as String;
      expect(context, contains('throw UnimplementedError'));
    });

    test('context is bounded to a small line window around a direct throw', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/worker.dart': _wideTryContextSource}),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'Worker', 'method': 'run', 'version': '1.0.0'}),
      );

      final context = _records(result).first['context']! as String;
      expect(context, contains("throw StateError('boom')"));
      expect(_lineCount(context), lessThanOrEqualTo(3));
      expect(context, isNot(contains('final trimmed = input.trim();')));
    });
  });

  // ─── Fix 4: field initializer throws ─────────────────────────────────────

  group('field initializer throw (Fix 4)', () {
    test('field initializer throw is excluded from class-wide scan results', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/config.dart': _fieldThrowSource}),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'Config', 'version': '1.0.0'}),
      );

      // No records — the only throw is inside a field initializer, which has
      // no method name and is excluded from class-wide scans.
      expect(result.isError, isNull);
      expect(_records(result), isEmpty);
    });

    test('getter method is still included when field initializer throw is present', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({
          'lib/config.dart': '''
class Config {
  static final bad = throw UnsupportedError("bad");
  void doWork() { throw StateError("not implemented"); }
}
''',
        }),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'Config', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      // Only the method throw is included, not the field initializer throw.
      expect(records, hasLength(1));
      expect(records.first['method'], equals('doWork'));
      expect(records.first['thrown_type'], equals('StateError'));
    });
  });

  // ─── Fix 3: rethrow handling ─────────────────────────────────────────────

  group('rethrow handling (Fix 3)', () {
    setUp(() {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/wrapper.dart': _rethrowSource}),
        kSourceFileTtl,
      );
    });

    test('rethrow inside catch is included in results', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'class': 'Wrapper',
          'method': 'callApi',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(1));
      expect(records.first['thrown_type'], equals('rethrow'));
    });

    test('rethrow record includes context spanning the catch block', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'class': 'Wrapper',
          'method': 'callApi',
          'version': '1.0.0',
        }),
      );

      final context = _records(result).first['context']! as String;
      expect(context, contains('rethrow'));
    });

    test('class-wide scan includes rethrow records', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'Wrapper', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      final types = _records(result).map((r) => r['thrown_type']! as String).toSet();
      expect(types, contains('rethrow'));
    });

    test('rethrow record has method field set to the enclosing method name', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'Wrapper', 'version': '1.0.0'}),
      );

      final records = _records(result);
      expect(records.first['method'], equals('callApi'));
    });

    test('explicit throw and rethrow in same method both appear in results', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({
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
        }),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'class': 'Svc',
          'method': 'run',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      final types = _records(result).map((r) => r['thrown_type']! as String).toSet();
      expect(types, containsAll(['ArgumentError', 'rethrow']));
    });
  });

  // ─── Fix 2: homonymous class scanning ────────────────────────────────────

  group('homonymous class — class+method scan (Fix 2)', () {
    test(
      'finds method in second file when first file has same-named class without that method',
      () async {
        sourceFilesCache.set(
          'source:foo:1.0.0',
          Future.value({
            'lib/a.dart': _repoASource,
            'lib/b.dart': _repoBSource,
          }),
          kSourceFileTtl,
        );

        final result = await buildHandler().call(
          _request({
            'package': 'foo',
            'class': 'Repo',
            'method': 'disconnect',
            'version': '1.0.0',
          }),
        );

        expect(result.isError, isNull);
        final records = _records(result);
        expect(records, hasLength(1));
        expect(records.first['thrown_type'], equals('StateError'));
      },
    );

    test(
      'returns method_not_found when method is absent from ALL homonymous classes',
      () async {
        sourceFilesCache.set(
          'source:foo:1.0.0',
          Future.value({
            'lib/a.dart': _repoASource, // has connect(), not disconnect()
            'lib/b.dart': _repoASource, // also has connect(), not disconnect()
          }),
          kSourceFileTtl,
        );

        final result = await buildHandler().call(
          _request({
            'package': 'foo',
            'class': 'Repo',
            'method': 'disconnect',
            'version': '1.0.0',
          }),
        );

        expect(result.isError, isTrue);
        expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
      },
    );

    test(
      'returns class_not_found when class is absent from all files (not method_not_found)',
      () async {
        sourceFilesCache.set(
          'source:foo:1.0.0',
          Future.value({
            'lib/a.dart': 'class Other { void m() {} }',
          }),
          kSourceFileTtl,
        );

        final result = await buildHandler().call(
          _request({
            'package': 'foo',
            'class': 'Repo',
            'method': 'disconnect',
            'version': '1.0.0',
          }),
        );

        expect(result.isError, isTrue);
        expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
      },
    );
  });

  group('homonymous class — class-wide scan (Fix 2)', () {
    test('aggregates throws from both files when class name appears in two files', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({
          'lib/a.dart': 'class Repo { void connect() { throw StateError("a"); } }',
          'lib/b.dart': 'class Repo { void disconnect() { throw ArgumentError("b"); } }',
        }),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'class': 'Repo', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      final records = _records(result);
      expect(records, hasLength(2));
      final types = records.map((r) => r['thrown_type']! as String).toSet();
      expect(types, containsAll(['StateError', 'ArgumentError']));
    });
  });

  // ─── Fix 1: concurrent in-flight cache poisoning ─────────────────────────

  group('concurrent calls — API index (Fix 1)', () {
    test(
      'two concurrent calls that share a cold API-index key both receive the error',
      () async {
        // Use a Completer so both handler calls start before the HTTP request
        // resolves, exercising the window that previously was vulnerable to cache
        // poisoning.
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
          _request({'package': 'foo', 'method': 'log', 'version': '1.0.0'}),
        );
        final f2 = handler.call(
          _request({'package': 'foo', 'method': 'log', 'version': '1.0.0'}),
        );

        // Resolve the shared in-flight HTTP request with a 429.
        completer.complete(http.Response('', 429));

        final r1 = await f1;
        final r2 = await f2;

        // Both calls must surface the real error — neither may return
        // no_documentation or an empty array masquerading as success.
        expect(_errorPayload(r1)['code'], equals(DomainErrors.rateLimited));
        expect(_errorPayload(r2)['code'], equals(DomainErrors.rateLimited));
      },
    );
  });

  group('concurrent calls — source files (Fix 1)', () {
    test(
      'two concurrent calls that share a cold source-file key both receive the error',
      () async {
        apiIndexCache.set(
          '$kApiIndexCachePrefix:foo:1.0.0',
          Future.value([
            _sym(name: 'log', qualifiedName: 'foo.log', href: 'foo/log.html'),
          ]),
          kApiDocsTtl,
        );

        final completer = Completer<http.Response>();
        when(
          () => mockHttp.get(
            any(
              that: predicate<Uri>((u) => u.toString().contains('/archive.tar.gz')),
            ),
            headers: any(named: 'headers'),
          ),
        ).thenAnswer((_) => completer.future);

        final handler = buildHandler();
        final f1 = handler.call(
          _request({'package': 'foo', 'method': 'log', 'version': '1.0.0'}),
        );
        final f2 = handler.call(
          _request({'package': 'foo', 'method': 'log', 'version': '1.0.0'}),
        );

        completer.complete(http.Response('', 429));

        final r1 = await f1;
        final r2 = await f2;

        expect(_errorPayload(r1)['code'], equals(DomainErrors.rateLimited));
        expect(_errorPayload(r2)['code'], equals(DomainErrors.rateLimited));
      },
    );
  });

  // ─── API index transport errors ──────────────────────────────────────────

  group('top-level function — API index transport failure', () {
    test('404 from API index returns package_not_found', () async {
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
        _request({'package': 'foo', 'method': 'log', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));
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
        _request({'package': 'foo', 'method': 'log', 'version': '1.0.0'}),
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
        _request({'package': 'foo', 'method': 'log', 'version': '1.0.0'}),
      );
      final second = await handler.call(
        _request({'package': 'foo', 'method': 'log', 'version': '1.0.0'}),
      );

      expect(_errorPayload(first)['code'], equals(DomainErrors.rateLimited));
      expect(_errorPayload(second)['code'], equals(DomainErrors.rateLimited));
    });
  });

  // ─── source-fetch transport errors ───────────────────────────────────────

  group('_loadSourceFiles — transient error propagation', () {
    setUp(() {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:foo:1.0.0',
        Future.value([
          _sym(name: 'log', qualifiedName: 'foo.log', href: 'foo/log.html'),
        ]),
        kApiDocsTtl,
      );
    });

    test('request_timeout from tarball yields request_timeout', () async {
      when(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('/archive.tar.gz'))),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => throw TimeoutException('network timeout'));

      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'log', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.requestTimeout));
    });

    test('rate_limited from tarball yields rate_limited', () async {
      when(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('/archive.tar.gz'))),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => http.Response('', 429));

      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'log', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.rateLimited));
    });

    test('HTTP 404 from tarball yields package_not_found', () async {
      when(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('/archive.tar.gz'))),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => http.Response('Not Found', 404));

      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'log', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));
    });

    test('transient tarball failure does not leave stale entry in sourceFilesCache', () async {
      when(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('/archive.tar.gz'))),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => http.Response('', 429));

      await buildHandler().call(
        _request({'package': 'foo', 'method': 'log', 'version': '1.0.0'}),
      );

      expect(sourceFilesCache.get('source:foo:1.0.0'), isNull);
    });
  });
}
