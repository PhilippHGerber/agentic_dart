/// Unit tests for [FindSymbolsHandler].
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pubdev_context/src/cache/cache_registry.dart';
import 'package:pubdev_context/src/cache/keyed_cache.dart';
import 'package:pubdev_context/src/data/domain_error.dart';
import 'package:pubdev_context/src/data/models.dart';
import 'package:pubdev_context/src/tools/find_symbols.dart';
import 'package:pubdev_context/src/tools/version_resolver.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';
import '../../support/pub_stubs.dart';

// ─── Helpers ──────────────────────────────────────────────────────────────────

/// Creates a [CallToolRequest] for `find_symbols` with the given [args].
CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'find_symbols', arguments: args);

/// Decodes the response body of [result] as a JSON object.
Map<String, Object?> _body(CallToolResult result) =>
    jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;

/// Returns the `symbols` list from a success [result].
List<Map<String, Object?>> _symbols(CallToolResult result) =>
    ((_body(result)['symbols'] as List<Object?>?) ?? const [])
        .cast<Map<String, Object?>>()
        .toList();

/// Decodes the nested error object of an error [result].
Map<String, Object?> _errorPayload(CallToolResult result) {
  final inner = _body(result)['error'];
  if (inner is! Map<String, Object?>) throw StateError('No nested error object');
  return inner;
}

/// Builds a synthetic index of [count] class symbols all matching `query`.
String _bulkIndex(int count) => jsonEncode([
  for (var i = 0; i < count; i++)
    {
      'name': 'Widget$i',
      'qualifiedName': 'flutter.Widget$i',
      'href': 'flutter/Widget$i-class.html',
      'kind': 3,
      'enclosedBy': {'name': 'flutter', 'kind': 9, 'href': 'flutter/'},
    },
]);

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late TestStack stack;
  late MockHttpClient mockHttp;
  late VersionResolver versionResolver;
  late DateTime fakeNow;
  late KeyedCache<ApiIndexId, List<DartdocSymbol>> apiIndex;
  final loggedMessages = <(LoggingLevel, Object)>[];

  FindSymbolsHandler buildHandler() => FindSymbolsHandler(
    versionResolver: versionResolver,
    apiIndex: apiIndex,
    log: (level, data) => loggedMessages.add((level, data)),
  );

  setUp(() {
    fakeNow = DateTime(2025, 5, 10);
    stack = TestStack(clock: () => fakeNow);
    mockHttp = stack.http;
    versionResolver = VersionResolver(
      client: stack.client,
      log: (level, data) => loggedMessages.add((level, data)),
    );
    apiIndex = stack.caches.apiIndex;
    loggedMessages.clear();
  });

  tearDown(() => stack.close());

  // ─── Argument validation ──────────────────────────────────────────────────────

  group('missing package', () {
    test('returns INVALID_ARGUMENT without calling the HTTP client', () async {
      final result = await buildHandler().call(_request({'query': 'client'}));

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
      verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
    });

    test('suggestedNextStep points at search_packages', () async {
      final result = await buildHandler().call(_request({'query': 'client'}));

      final next = _errorPayload(result)['suggestedNextStep'] as Map<String, Object?>?;
      expect(next?['tool'], equals('search_packages'));
    });
  });

  group('missing query', () {
    test('returns INVALID_ARGUMENT without calling the HTTP client', () async {
      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.invalidArgument));
      verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
    });
  });

  // ─── Found symbols ────────────────────────────────────────────────────────────

  group('found symbols', () {
    test('returns a non-error result for a query with known matches', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(result.isError, isNull);
      expect(_symbols(result), isNotEmpty);
    });

    test('each entry carries the full result shape', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'BrowserClient'}),
      );

      final match = _symbols(result).firstWhere((s) => s['name'] == 'BrowserClient');
      expect(
        match.keys,
        containsAll(<String>[
          'name',
          'qualifiedName',
          'kind',
          'library',
          'enclosedBy',
          'description',
          'href',
        ]),
      );
      expect(match['kind'], equals('class'));
      expect(match['library'], equals('package:http/browser_client.dart'));
    });

    test('a class reports a null enclosedBy', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'BrowserClient'}),
      );

      final klass = _symbols(result).firstWhere((s) => s['name'] == 'BrowserClient');
      expect(klass['enclosedBy'], isNull);
    });

    test('a member reports its enclosing class as enclosedBy', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'withCredentials'}),
      );

      final member = _symbols(result).firstWhere((s) => s['name'] == 'withCredentials');
      expect(member['enclosedBy'], equals('BrowserClient'));
    });

    test('name matches rank before description-only matches', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      // "abort" is in the name of Abortable/abortTrigger and in descriptions.
      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      final names = _symbols(result).map((s) => s['name']! as String).toList();
      // "close" matches only by description ("Closes the client.").
      final closeIdx = names.indexOf('close');
      final nameMatchIdx = names
          .asMap()
          .entries
          .where((e) => e.value.toLowerCase().contains('client'))
          .map((e) => e.key);
      if (closeIdx >= 0) {
        expect(nameMatchIdx.every((i) => i < closeIdx), isTrue);
      }
    });
  });

  // ─── Empty results ────────────────────────────────────────────────────────────

  group('empty results', () {
    test('returns an empty symbols array (no error) when nothing matches', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'zzznomatch123'}),
      );

      expect(result.isError, isNull);
      expect(_symbols(result), isEmpty);
    });
  });

  // ─── hasMore ──────────────────────────────────────────────────────────────────

  group('hasMore', () {
    test('is absent when 20 or fewer matches exist', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _bulkIndex(20));

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'Widget'}),
      );

      expect(_symbols(result).length, equals(20));
      expect(_body(result).containsKey('hasMore'), isFalse);
    });

    test('is true and results are capped at 20 when more matches exist', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _bulkIndex(25));

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'Widget'}),
      );

      expect(_symbols(result).length, equals(20));
      expect(_body(result)['hasMore'], isTrue);
    });
  });

  // ─── resolvedVersion ──────────────────────────────────────────────────────────

  group('resolvedVersion', () {
    test('equals the resolved latest stable when version is omitted', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(_body(result)['resolvedVersion'], equals('1.6.0'));
    });

    test('echoes a pinned version without resolving', () async {
      stubIndexJson(mockHttp, version: '1.2.0');

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client', 'version': '1.2.0'}),
      );

      expect(_body(result)['resolvedVersion'], equals('1.2.0'));
    });
  });

  // ─── Shared cache ─────────────────────────────────────────────────────────────

  group('apiIndex facade', () {
    test('issues only one index request across two calls to the same package', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);
      final handler = buildHandler();

      await handler.call(_request({'package': 'http', 'query': 'client'}));
      fakeNow = fakeNow.add(const Duration(minutes: 30));
      await handler.call(_request({'package': 'http', 'query': 'send'}));

      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/1.6.0/index.json'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });
  });

  // ─── Missing dartdoc ──────────────────────────────────────────────────────────

  group('missing dartdoc', () {
    test('returns NO_DOCUMENTATION when the index is 404', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, statusCode: 404);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.noDocumentation));
    });

    test('returns NO_DOCUMENTATION when the index is an empty array', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: '[]');

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(_errorPayload(result)['code'], equals(DomainErrors.noDocumentation));
    });
  });
}
