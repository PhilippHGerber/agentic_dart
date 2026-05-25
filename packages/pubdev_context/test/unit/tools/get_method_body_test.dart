/// Unit tests for [GetMethodBodyHandler].
library;

import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:pubdev_context/src/cache/memory_cache.dart';
import 'package:pubdev_context/src/data/domain_error.dart';
import 'package:pubdev_context/src/data/models.dart';
import 'package:pubdev_context/src/data/pub_client.dart';
import 'package:pubdev_context/src/tools/browse_api_symbols.dart';
import 'package:pubdev_context/src/tools/get_method_body.dart';
import 'package:test/test.dart';

// ─── Mocks ────────────────────────────────────────────────────────────────────

class _MockHttpClient extends Mock implements http.Client {}

// ─── Dart source fixtures ──────────────────────────────────────────────────────

/// A Dart source file that declares `class Calculator`.
///
/// Includes a default (unnamed) constructor so tests can exercise the `"new"`
/// sentinel without a separate fixture.
const _calculatorSource = r'''
/// A simple calculator.
class Calculator {
  int add(int a, int b) => a + b;

  int subtract(int a, int b) => a - b;

  bool operator ==(Object other) =>
      other is Calculator;

  @override
  int get hashCode => 0;

  set label(String v) {
    _label = v;
  }

  String get label => _label;

  String _label = '';

  Calculator();

  Calculator.fromValues(int a, int b) : _label = '$a+$b';

  static Calculator create() => Calculator();
}
''';

/// A Dart source file whose only class has a named constructor and no default
/// constructor.  Used to verify that `"new"` returns `method_not_found` when
/// the default constructor is absent.
const _namedOnlyCtorSource = '''
class Named {
  Named.create();
}
''';

/// A Dart source file that declares a top-level function `compute`.
const _computeSource = '''
int compute(int x) => x * 2;

String format(String s) => s.trim();
''';

/// A Dart source file that declares a mixin `Printable`.
const _mixinSource = '''
mixin Printable {
  void printSelf() {
    print(toString());
  }
}
''';

/// A Dart source file that declares an enum `Status`.
const _enumSource = '''
enum Status {
  active,
  inactive;

  bool get isActive => this == Status.active;
}
''';

// ─── Helpers ──────────────────────────────────────────────────────────────────

RetryPolicy get _instant => RetryPolicy(delay: (_) async {});

/// Creates a minimal [DartdocSymbol] for test use.
DartdocSymbol _sym({
  required String name,
  required String qualifiedName,
  required String href,
  String type = 'function',
  String desc = '',
}) => DartdocSymbol(name: name, qualifiedName: qualifiedName, href: href, type: type, desc: desc);

/// Creates a [CallToolRequest] for `get_method_body` with the given [args].
CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'get_method_body', arguments: args);

/// Decodes the first content item of [result] as a JSON error payload.
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

/// Returns the plain-text content from the first content item of [result].
String _text(CallToolResult result) => (result.content.first as TextContent).text;

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late _MockHttpClient mockHttp;
  late PubDevClient client;
  late ResponseCache<Map<String, String>> sourceFilesCache;
  late ResponseCache<List<DartdocSymbol>> apiIndexCache;
  final loggedMessages = <(LoggingLevel, Object)>[];

  GetMethodBodyHandler buildHandler() => GetMethodBodyHandler(
    client: client,
    sourceFilesCache: sourceFilesCache,
    apiIndexCache: apiIndexCache,
    log: (level, data) => loggedMessages.add((level, data)),
  );

  setUp(() {
    mockHttp = _MockHttpClient();
    registerFallbackValue(Uri.parse('https://pub.dev'));
    client = PubDevClient(httpClient: mockHttp, retryPolicy: _instant);
    sourceFilesCache = ResponseCache();
    apiIndexCache = ResponseCache();
    loggedMessages.clear();
  });

  tearDown(() => client.close());

  // ─── invalid_input ─────────────────────────────────────────────────────────

  group('invalid_input', () {
    test('returns invalid_input when method is empty string', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': ''}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('returns invalid_input when method is missing from args', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('invalid_input payload contains message and suggestion', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': ''}),
      );

      expect(_errorPayload(result), contains('message'));
      expect(_errorPayload(result), contains('suggestion'));
    });

    test('suggestion mentions class name when class was also provided', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': '', 'class': 'MyClass'}),
      );

      expect(_errorPayload(result)['suggestion'], contains('MyClass'));
    });
  });

  // ─── class + method: regular methods ───────────────────────────────────────

  group('class + method — regular method', () {
    setUp(() {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/calculator.dart': _calculatorSource}),
        kSourceFileTtl,
      );
    });

    test('returns source text of a named method', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'add', 'class': 'Calculator', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      final text = _text(result);
      expect(text, contains('int add(int a, int b)'));
    });

    test('returned text does not include methods of other names', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'add', 'class': 'Calculator', 'version': '1.0.0'}),
      );

      expect(_text(result), isNot(contains('subtract')));
    });

    test('returns static method body', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'method': 'create',
          'class': 'Calculator',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      expect(_text(result), contains('Calculator create()'));
    });
  });

  // ─── class + method: operator normalisation ────────────────────────────────

  group('class + method — operator normalisation', () {
    setUp(() {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/calculator.dart': _calculatorSource}),
        kSourceFileTtl,
      );
    });

    test('"==" resolves to operator == body', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': '==', 'class': 'Calculator', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      expect(_text(result), contains('operator =='));
    });

    test('"operator ==" resolves to operator == body', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'method': 'operator ==',
          'class': 'Calculator',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      expect(_text(result), contains('operator =='));
    });

    test('"==" and "operator ==" return identical text', () async {
      final handler = buildHandler();

      final r1 = await handler.call(
        _request({'package': 'foo', 'method': '==', 'class': 'Calculator', 'version': '1.0.0'}),
      );
      final r2 = await handler.call(
        _request({
          'package': 'foo',
          'method': 'operator ==',
          'class': 'Calculator',
          'version': '1.0.0',
        }),
      );

      expect(_text(r1), equals(_text(r2)));
    });
  });

  // ─── class + method: getter and setter ────────────────────────────────────

  group('class + method — getter and setter', () {
    setUp(() {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/calculator.dart': _calculatorSource}),
        kSourceFileTtl,
      );
    });

    test('returns getter body when only getter exists', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'method': 'hashCode',
          'class': 'Calculator',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      expect(_text(result), contains('get hashCode'));
    });

    test('returns both getter and setter when both exist for same name', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'label', 'class': 'Calculator', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      final text = _text(result);
      expect(text, contains('get label'));
      expect(text, contains('set label'));
    });

    test('getter+setter response is labelled with "// getter" and "// setter"', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'label', 'class': 'Calculator', 'version': '1.0.0'}),
      );

      final text = _text(result);
      expect(text, contains('// getter'));
      expect(text, contains('// setter'));
    });
  });

  // ─── class + method: named constructor ────────────────────────────────────

  group('class + method — named constructor', () {
    setUp(() {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/calculator.dart': _calculatorSource}),
        kSourceFileTtl,
      );
    });

    test('returns named constructor body by suffix', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'method': 'fromValues',
          'class': 'Calculator',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      expect(_text(result), contains('Calculator.fromValues'));
    });
  });

  // ─── class + method: default constructor ──────────────────────────────────

  group('class + method — default constructor', () {
    setUp(() {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/calculator.dart': _calculatorSource}),
        kSourceFileTtl,
      );
    });

    test('returns default constructor body when method is "new"', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'method': 'new',
          'class': 'Calculator',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      expect(_text(result), contains('Calculator()'));
    });

    test('"new" does not include a named constructor in the returned text', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'method': 'new',
          'class': 'Calculator',
          'version': '1.0.0',
        }),
      );

      expect(_text(result), isNot(contains('fromValues')));
    });

    test('method_not_found when class has no default constructor and method is "new"', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/named.dart': _namedOnlyCtorSource}),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'method': 'new',
          'class': 'Named',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
    });

    test('"new" and a named constructor can coexist — "fromValues" still resolves', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'method': 'fromValues',
          'class': 'Calculator',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      expect(_text(result), contains('Calculator.fromValues'));
    });
  });

  // ─── class + method: mixin and enum ───────────────────────────────────────

  group('class + method — mixin', () {
    setUp(() {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/mixin.dart': _mixinSource}),
        kSourceFileTtl,
      );
    });

    test('finds a method declared in a mixin', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'method': 'printSelf',
          'class': 'Printable',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      expect(_text(result), contains('void printSelf()'));
    });
  });

  group('class + method — enum', () {
    setUp(() {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/status.dart': _enumSource}),
        kSourceFileTtl,
      );
    });

    test('finds a getter declared in an enum', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'method': 'isActive',
          'class': 'Status',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isNull);
      expect(_text(result), contains('get isActive'));
    });
  });

  // ─── class_not_found ───────────────────────────────────────────────────────

  group('class_not_found', () {
    setUp(() {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/calculator.dart': _calculatorSource}),
        kSourceFileTtl,
      );
    });

    test('returns class_not_found when class is absent', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'method': 'doSomething',
          'class': 'NonExistent',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
    });

    test('class_not_found payload has message and suggestion', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'method': 'doSomething',
          'class': 'NonExistent',
          'version': '1.0.0',
        }),
      );

      expect(_errorPayload(result), contains('message'));
      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  // ─── method_not_found ──────────────────────────────────────────────────────

  group('method_not_found', () {
    setUp(() {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/calculator.dart': _calculatorSource}),
        kSourceFileTtl,
      );
    });

    test('returns method_not_found when method is absent from class', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'method': 'multiply',
          'class': 'Calculator',
          'version': '1.0.0',
        }),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
    });

    test('method_not_found payload contains message and suggestion', () async {
      final result = await buildHandler().call(
        _request({
          'package': 'foo',
          'method': 'multiply',
          'class': 'Calculator',
          'version': '1.0.0',
        }),
      );

      expect(_errorPayload(result), contains('message'));
      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  // ─── top-level function extraction ────────────────────────────────────────

  group('top-level function — single match', () {
    setUp(() {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:foo',
        Future.value([_sym(name: 'compute', qualifiedName: 'foo.compute', href: 'foo/compute.html')]),
        kApiDocsTtl,
      );
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/foo.dart': _computeSource}),
        kSourceFileTtl,
      );
    });

    test('returns function body for a top-level function', () async {
      // Note: version must be resolvable without HTTP — stub the package API.
      _stubPackageVersion(mockHttp, name: 'foo', version: '1.0.0');

      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'compute'}),
      );

      expect(result.isError, isNull);
      expect(_text(result), contains('int compute(int x)'));
    });

    test('does not include other functions in the returned text', () async {
      _stubPackageVersion(mockHttp, name: 'foo', version: '1.0.0');

      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'compute'}),
      );

      expect(_text(result), isNot(contains('format')));
    });
  });

  group('top-level function — with explicit version', () {
    setUp(() {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:foo:1.0.0',
        Future.value([_sym(name: 'compute', qualifiedName: 'foo.compute', href: 'foo/compute.html')]),
        kApiDocsTtl,
      );
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/foo.dart': _computeSource}),
        kSourceFileTtl,
      );
    });

    test('uses explicit version in the API index cache key', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'compute', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      expect(_text(result), contains('int compute'));
    });
  });

  group('top-level function — qualifiedName suffix resolution', () {
    test('strips library prefix from qualifiedName to match method', () async {
      apiIndexCache.set(
        '$kApiIndexCachePrefix:foo:1.0.0',
        Future.value([
          _sym(name: 'compute', qualifiedName: 'foo.compute', href: 'foo/compute.html'),
        ]),
        kApiDocsTtl,
      );
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/foo.dart': _computeSource}),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'compute', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
    });
  });

  // ─── ambiguous_symbol ─────────────────────────────────────────────────────

  group('ambiguous_symbol', () {
    test('returns ambiguous_symbol when multiple functions match the name', () async {
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
  });

  // ─── top-level function method_not_found ──────────────────────────────────

  group('top-level function — method_not_found', () {
    test('returns method_not_found when no function matches in the API index', () async {
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

    test('non-function symbols are excluded from top-level function search', () async {
      // Provide a class symbol with name matching the requested method.
      apiIndexCache.set(
        '$kApiIndexCachePrefix:foo:1.0.0',
        Future.value([
          _sym(name: 'compute', qualifiedName: 'foo.compute', href: 'foo/compute.html', type: 'class'),
        ]),
        kApiDocsTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'compute', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
    });
  });

  // ─── AST cache behavior ───────────────────────────────────────────────────

  group('AST cache', () {
    test('reuses the parsed AST on repeated calls for the same file', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/calculator.dart': _calculatorSource}),
        kSourceFileTtl,
      );

      final handler = buildHandler();

      await handler.call(
        _request({'package': 'foo', 'method': 'add', 'class': 'Calculator', 'version': '1.0.0'}),
      );
      loggedMessages.clear();

      await handler.call(
        _request({
          'package': 'foo',
          'method': 'subtract',
          'class': 'Calculator',
          'version': '1.0.0',
        }),
      );

      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString());
      expect(debugLogs.any((m) => m.contains('AST cache hit')), isTrue);
    });
  });

  // ─── source files cache sharing ───────────────────────────────────────────

  group('source files cache sharing', () {
    test('cache key uses source:<package>:<version> format', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/calculator.dart': _calculatorSource}),
        kSourceFileTtl,
      );

      await buildHandler().call(
        _request({'package': 'foo', 'method': 'add', 'class': 'Calculator', 'version': '1.0.0'}),
      );

      // If the call succeeded, it used the cache entry we pre-populated — no HTTP.
      verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
    });
  });

  // ─── multi-file packages ──────────────────────────────────────────────────

  group('multi-file package', () {
    test('finds a class declared in a non-first file', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({
          'lib/foo.dart': _computeSource,
          'lib/calculator.dart': _calculatorSource,
        }),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'add', 'class': 'Calculator', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      expect(_text(result), contains('int add'));
    });

    test('searches lib/ files before other directories', () async {
      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({
          'test/calculator_test.dart': '// not a lib file',
          'lib/calculator.dart': _calculatorSource,
        }),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'add', 'class': 'Calculator', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
    });
  });

  // ─── package_not_found ────────────────────────────────────────────────────

  group('package_not_found', () {
    test('returns package_not_found when version resolution fails', () async {
      when(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('/api/packages/missing'))),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => http.Response('Not Found', 404));

      final result = await buildHandler().call(
        _request({'package': 'missing', 'method': 'foo', 'class': 'Bar'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));
    });
  });

  // ─── Bug 32: qualified-name retry ─────────────────────────────────────────

  group('top-level function — qualified-name retry', () {
    setUp(() {
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
          // Raw strings avoid escaping the $ in Dart source fixtures.
          'lib/foo.dart': r'void log(String message) => print("[foo] $message");',
          'lib/bar.dart': r'void log(String message) => print("[bar] $message");',
        }),
        kSourceFileTtl,
      );
    });

    test('unqualified name with two candidates returns ambiguous_symbol with two candidates',
        () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'log', 'version': '1.0.0'}),
      );

      expect(result.isError, isTrue);
      final payload = _errorPayload(result);
      expect(payload['code'], equals(DomainErrors.ambiguousSymbol));
      final candidates = _candidates(payload);
      expect(candidates, hasLength(2));
      expect(candidates, containsAll(['foo.log', 'bar.log']));
    });

    test('qualified retry "foo.log" resolves to the function body in lib/foo.dart', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'foo.log', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      expect(_text(result), contains('[foo]'));
    });

    test('qualified retry "bar.log" resolves to the function body in lib/bar.dart', () async {
      final result = await buildHandler().call(
        _request({'package': 'foo', 'method': 'bar.log', 'version': '1.0.0'}),
      );

      expect(result.isError, isNull);
      expect(_text(result), contains('[bar]'));
    });

    test('unqualified lookup with a single candidate still resolves correctly (regression guard)',
        () async {
      // Override to a different package with a single `compute` symbol so the
      // suffix-match initial path is exercised without interference from the
      // two-candidate setup above.
      apiIndexCache.set(
        '$kApiIndexCachePrefix:baz:3.0.0',
        Future.value([
          _sym(name: 'compute', qualifiedName: 'baz.compute', href: 'baz/compute.html'),
        ]),
        kApiDocsTtl,
      );
      sourceFilesCache.set(
        'source:baz:3.0.0',
        Future.value({'lib/baz.dart': 'int compute(int x) => x * 2;'}),
        kSourceFileTtl,
      );

      final result = await buildHandler().call(
        _request({'package': 'baz', 'method': 'compute', 'version': '3.0.0'}),
      );

      expect(result.isError, isNull);
      expect(_text(result), contains('int compute(int x)'));
    });

    // ── Bug fix: qualified retry must not fall back to the global scan ────────

    test(
      'qualified retry returns method_not_found when hint path is absent — '
      'does not return wrong homonym from another file',
      () async {
        // href "foo/log.html" → hintPaths ["lib/foo.dart", "lib/src/foo.dart"].
        // Neither key exists in this source map; only lib/utils.dart does.
        // A global fallback scan would find log() there — the wrong function.
        // The qualified-only strategy must return method_not_found instead.
        sourceFilesCache.set(
          'source:foo:1.0.0',
          Future.value({
            'lib/utils.dart': r'void log(String msg) => print("[utils] $msg");',
          }),
          kSourceFileTtl,
        );

        final result = await buildHandler().call(
          _request({'package': 'foo', 'method': 'foo.log', 'version': '1.0.0'}),
        );

        expect(result.isError, isTrue);
        expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
      },
    );

    test(
      'qualified retry resolves correctly when function lives under lib/src/',
      () async {
        // href "foo/log.html" → secondary hint "lib/src/foo.dart" must be tried.
        // lib/bar.dart has a homonymous log() that must NOT be returned.
        sourceFilesCache.set(
          'source:foo:1.0.0',
          Future.value({
            'lib/src/foo.dart': r'void log(String msg) => print("[src-foo] $msg");',
            'lib/bar.dart': r'void log(String msg) => print("[bar] $msg");',
          }),
          kSourceFileTtl,
        );

        final result = await buildHandler().call(
          _request({'package': 'foo', 'method': 'foo.log', 'version': '1.0.0'}),
        );

        expect(result.isError, isNull);
        expect(_text(result), contains('[src-foo]'));
        expect(_text(result), isNot(contains('[bar]')));
      },
    );

    test(
      'unqualified lookup still falls back to global scan when hint path is absent',
      () async {
        // Verify that the global-fallback restriction applies ONLY to qualified
        // retries.  For unqualified "compute" with a single API-index match,
        // the function must still be found even when the hint file is absent.
        apiIndexCache.set(
          '$kApiIndexCachePrefix:qux:1.0.0',
          Future.value([
            // href "qux/compute.html" → hint "lib/qux.dart" — absent below.
            _sym(
              name: 'compute',
              qualifiedName: 'qux.compute',
              href: 'qux/compute.html',
            ),
          ]),
          kApiDocsTtl,
        );
        sourceFilesCache.set(
          'source:qux:1.0.0',
          Future.value({
            // Stored under a different name so the hint misses.
            'lib/utils.dart': 'int compute(int x) => x * 2;',
          }),
          kSourceFileTtl,
        );

        final result = await buildHandler().call(
          _request({'package': 'qux', 'method': 'compute', 'version': '1.0.0'}),
        );

        expect(result.isError, isNull);
        expect(_text(result), contains('int compute(int x)'));
      },
    );
  });

  // ─── Bug 33: API index transport errors must not be cached as empty list ───

  group('top-level function — API index transport failure', () {
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

    test('second call after rate_limited also returns rate_limited, not no_documentation',
        () async {
      // Before the fix, the first call would leave a pre-set empty-list Future
      // in the cache. The second call would hit that cache entry, get [], and
      // return no_documentation — wrong recovery guidance for a transient error.
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

    test('successful API index fetch returns function body and caches the result', () async {
      // `kind: 8` maps to type "function" in DartdocSymbol.fromJson.
      final indexJson = jsonEncode([
        {'name': 'log', 'qualifiedName': 'foo.log', 'href': 'foo/log.html', 'kind': 8, 'desc': ''},
      ]);
      when(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/foo/1.0.0/index.json'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => http.Response(indexJson, 200));

      sourceFilesCache.set(
        'source:foo:1.0.0',
        Future.value({'lib/foo.dart': 'void log(String msg) {}'}),
        kSourceFileTtl,
      );

      final handler = buildHandler();

      final first = await handler.call(
        _request({'package': 'foo', 'method': 'log', 'version': '1.0.0'}),
      );
      // Second call must not issue a new HTTP request — the resolved value is
      // cached by the overwrite added in Bug 33's fix.
      final second = await handler.call(
        _request({'package': 'foo', 'method': 'log', 'version': '1.0.0'}),
      );

      expect(first.isError, isNull);
      expect(second.isError, isNull);
      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/foo/1.0.0/index.json'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });
  });

  // ─── Bug 34: source-fetch transient errors must propagate correctly ────────

  group('_loadSourceFiles — transient error propagation', () {
    setUp(() {
      // Pre-populate the API index so only the tarball request is exercised.
      apiIndexCache.set(
        '$kApiIndexCachePrefix:foo:1.0.0',
        Future.value([_sym(name: 'log', qualifiedName: 'foo.log', href: 'foo/log.html')]),
        kApiDocsTtl,
      );
    });

    test('request_timeout from tarball yields request_timeout, not package_not_found', () async {
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

    test('rate_limited from tarball yields rate_limited, not package_not_found', () async {
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

    test('HTTP 404 from tarball still yields package_not_found (regression guard)', () async {
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

    test('transient tarball failure does not leave a stale entry in sourceFilesCache', () async {
      when(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('/archive.tar.gz'))),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => http.Response('', 429));

      await buildHandler().call(
        _request({'package': 'foo', 'method': 'log', 'version': '1.0.0'}),
      );

      // The cache entry should have been invalidated so a future successful
      // call does not silently use an empty-map future.
      expect(sourceFilesCache.get('source:foo:1.0.0'), isNull);
    });
  });
}

// ─── HTTP stub helpers ────────────────────────────────────────────────────────

/// Stubs the package info and score endpoints to return [version] as latest.
void _stubPackageVersion(
  _MockHttpClient mock, {
  required String name,
  required String version,
}) {
  final packageBody = jsonEncode({
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
    'grantedPoints': 100,
    'maxPoints': 130,
    'downloadCount30Days': 1000,
    'tags': <String>[],
  });

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
  ).thenAnswer((_) async => http.Response(packageBody, 200));

  when(
    () => mock.get(
      any(
        that: predicate<Uri>((u) => u.toString().contains('/api/packages/$name/score')),
      ),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer((_) async => http.Response(scoreBody, 200));

  // Stub the documentation page (used by getPackage internally).
  when(
    () => mock.get(
      any(
        that: predicate<Uri>((u) => u.toString().contains('/documentation/$name/')),
      ),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer((_) async => http.Response('Not Found', 404));
}
