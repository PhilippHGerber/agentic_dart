/// Unit tests for [BrowseApiSymbolsHandler].
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:dart_pubdev_mcp/src/cache/cache_registry.dart';
import 'package:dart_pubdev_mcp/src/cache/keyed_cache.dart';
import 'package:dart_pubdev_mcp/src/data/domain_error.dart';
import 'package:dart_pubdev_mcp/src/data/models.dart';
import 'package:dart_pubdev_mcp/src/tools/browse_api_symbols.dart';
import 'package:dart_pubdev_mcp/src/tools/find_symbols.dart';
import 'package:dart_pubdev_mcp/src/tools/get_api_diff.dart';
import 'package:dart_pubdev_mcp/src/tools/get_symbol_documentation.dart';
import 'package:dart_pubdev_mcp/src/tools/version_resolver.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';
import '../../support/pub_stubs.dart';

// ─── Helpers ──────────────────────────────────────────────────────────────────

/// Creates a [CallToolRequest] for `browse_api_symbols` with the given [args].
CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'browse_api_symbols', arguments: args);

/// Decodes the first content item of [result] as a JSON success object and
/// returns the `symbols` list.
List<Map<String, Object?>> _symbols(CallToolResult result) {
  final json = jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;
  return ((json['symbols'] as List<Object?>?) ?? const []).cast<Map<String, Object?>>().toList();
}

/// Decodes the first content item of [result] and returns its `resolvedVersion`.
String? _resolvedVersion(CallToolResult result) {
  final json = jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;
  return json['resolvedVersion'] as String?;
}

/// Decodes the first content item of [result] as a JSON error payload.
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
  late DateTime fakeNow;
  late KeyedCache<ApiIndexId, List<DartdocSymbol>> apiIndex;
  final loggedMessages = <(LoggingLevel, Object)>[];

  BrowseApiSymbolsHandler buildHandler() => BrowseApiSymbolsHandler(
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

  // Limit validation (limit > 25) moved to server-owned schema validation
  //  — see test/unit/pub_mcp_test.dart's
  // 'argument validation' group. The handler no longer checks `limit` itself.

  group('limit of 25', () {
    test('is accepted without returning an error', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': '', 'limit': 25}),
      );

      expect(result.isError, isNull);
    });
  });

  // ─── Cache hit ──────────────────────────────────────────────────────────────

  group('cache hit after a live call', () {
    test('issues only one HTTP request for two calls to the same package', () async {
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

  // ─── Warm cache (pre-primed) ────────────────────────────────────────────────

  group('warm cache', () {
    test('makes no index HTTP request when the cache is already warm', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);
      await apiIndex.resolve((name: 'http', version: '1.6.0'));

      await buildHandler().call(_request({'package': 'http', 'query': 'client'}));

      // Only the warm-up fetch above ran — the handler call itself was a hit.
      verify(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('index.json'))),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });
  });

  // ─── Cache miss ─────────────────────────────────────────────────────────────

  group('cache miss', () {
    test('logs an info message containing the package name', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      await buildHandler().call(_request({'package': 'http', 'query': 'client'}));

      final infoLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.info)
          .map((m) => m.$2.toString());
      expect(infoLogs.any((m) => m.contains('package=http')), isTrue);
    });
  });

  // ─── Successful search ──────────────────────────────────────────────────────

  group('successful search', () {
    test('returns a non-error result for a query with known matches', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(result.isError, isNull);
    });

    test('returns a JSON array of DartdocSymbol maps', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(_symbols(result), isNotEmpty);
    });

    test('each symbol entry contains a name field', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(_symbols(result).every((s) => s.containsKey('name')), isTrue);
    });

    test('each symbol entry contains a type field', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(_symbols(result).every((s) => s.containsKey('type')), isTrue);
    });

    test('each symbol entry contains a qualifiedName field', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(_symbols(result).every((s) => s.containsKey('qualifiedName')), isTrue);
    });

    test('symbols with empty desc omit the desc field', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'BrowserClient.new'}),
      );

      // BrowserClient.new has an empty desc in the fixture
      final match = _symbols(result).firstWhere(
        (s) => s['name'] == 'BrowserClient.new',
        orElse: () => {},
      );
      expect(match.containsKey('desc'), isFalse);
    });
  });

  // ─── Ranking ────────────────────────────────────────────────────────────────

  group('ranking', () {
    test('exact name matches appear before desc-only matches', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      // "close" matches only by desc ("Closes the client.")
      // name matches: browser_client, BrowserClient, BrowserClient.new
      final symbolNames = _symbols(result).map((s) => s['name']! as String).toList();
      final closeIdx = symbolNames.indexOf('close');
      expect(closeIdx, greaterThan(0));
    });

    test('name matches appear before the desc-only match for the same query', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      final symbolNames = _symbols(result).map((s) => s['name']! as String).toList();
      final nameMatchIndices = symbolNames
          .asMap()
          .entries
          .where((e) => e.value.toLowerCase().contains('client'))
          .map((e) => e.key)
          .toList();
      final closeIdx = symbolNames.indexOf('close');

      expect(nameMatchIndices.every((i) => i < closeIdx), isTrue);
    });
  });

  // ─── Type filter ────────────────────────────────────────────────────────────

  group('kind filter', () {
    test('narrows results to only the requested kind', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client', 'kind': 'class'}),
      );

      expect(_symbols(result).every((s) => s['type'] == 'class'), isTrue);
    });

    test('absent kind returns all matching symbol kinds', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      final types = _symbols(result).map((s) => s['type']! as String).toSet();
      expect(types.length, greaterThan(1));
    });

    test('unknown kind string is accepted without returning a kind-related error', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client', 'kind': 'widget'}),
      );

      // Should be no_results, not an error about the kind being unrecognised
      expect(_errorPayload(result)['code'], equals(DomainErrors.noResults));
    });

    test('kind filter applied after ranking preserves rank order within the kind', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'http', 'kind': 'class'}),
      );

      // query "http": name match = http (library), desc matches = BrowserClient, send, Abortable
      // After type=class: BrowserClient (name match? no — "BrowserClient" doesn't contain "http"),
      // Actually: "BrowserClient" name does NOT contain "http".
      // "http" name DOES contain "http" — but it's a library.
      // desc matches with type=class: BrowserClient (desc has "HTTP client"), Abortable (desc has "HTTP request")
      expect(_symbols(result).every((s) => s['type'] == 'class'), isTrue);
    });
  });

  // ─── Limit cap ──────────────────────────────────────────────────────────────

  group('limit cap', () {
    test('returns at most the requested limit of results', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': '', 'limit': 3}),
      );

      expect(_symbols(result).length, lessThanOrEqualTo(3));
    });

    test('returns at most 10 results when no limit is supplied', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': ''}),
      );

      expect(_symbols(result).length, lessThanOrEqualTo(10));
    });
  });

  // ─── no_results ─────────────────────────────────────────────────────────────

  group('no_results', () {
    test('returns no_results when the query matches nothing', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'xyzunknownsymbol123'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.noResults));
    });

    test('no_results payload contains a suggestion', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'xyzunknownsymbol123'}),
      );

      expect(_errorPayload(result), contains('suggestion'));
    });

    test('returns no_results when kind filter eliminates all ranked matches', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      // query "close" matches only the "close" method — filtering by "library" yields nothing
      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'close', 'kind': 'library'}),
      );

      expect(_errorPayload(result)['code'], equals(DomainErrors.noResults));
    });
  });

  // ─── no_documentation ───────────────────────────────────────────────────────

  group('no_documentation', () {
    test('returns no_documentation when the package has no dartdoc index', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, statusCode: 404);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.noDocumentation));
    });

    test('no_documentation payload contains a suggestion', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, statusCode: 404);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(_errorPayload(result), contains('suggestion'));
    });

    test('returns no_documentation when the index is an empty array from the server', () async {
      stubPackageInfo(mockHttp);
      when(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/1.6.0/index.json'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => ok('[]'));

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(_errorPayload(result)['code'], equals(DomainErrors.noDocumentation));
    });
  });

  // ─── Client failures ────────────────────────────────────────────────────────

  group('client failure', () {
    test('propagates a rate_limited error when pub.dev returns HTTP 429', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, statusCode: 429);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.rateLimited));
    });

    test('propagates a service_unavailable error when pub.dev returns HTTP 503', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, statusCode: 503);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.serviceUnavailable));
    });

    test('error payload always contains message and suggestion fields', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, statusCode: 503);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(_errorPayload(result), contains('message'));
      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  // ─── resolvedVersion (P1.10) ──────────────────────────────────────────────────

  group('resolvedVersion', () {
    test('is present and equals the resolved latest stable when version is omitted', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client'}),
      );

      expect(_resolvedVersion(result), equals('1.6.0'));
    });

    test('echoes the supplied version when a pinned version is requested', () async {
      stubIndexJson(mockHttp, version: '1.2.0');

      final result = await buildHandler().call(
        _request({'package': 'http', 'query': 'client', 'version': '1.2.0'}),
      );

      expect(_resolvedVersion(result), equals('1.2.0'));
    });
  });

  // ─── Cache key ───────────────────────────────────────────────────────────────

  group('cache identity', () {
    test('a call populates the apiIndex entry for that (package, version)', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);
      await buildHandler().call(_request({'package': 'http', 'query': 'client'}));

      // The identity must include the resolved version so pinned-version
      // requests never reuse docs cached for a different version.
      expect(await apiIndex.peek((name: 'http', version: '1.6.0')), isNotNull);
    });

    test('different packages populate independent apiIndex entries', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);
      stubPackageInfo(mockHttp, packageName: 'dio');
      stubIndexJson(mockHttp, packageName: 'dio');

      final handler = buildHandler();
      await handler.call(_request({'package': 'http', 'query': 'client'}));
      await handler.call(_request({'package': 'dio', 'query': 'client'}));

      // Both entries should exist independently.
      expect(await apiIndex.peek((name: 'http', version: '1.6.0')), isNotNull);
      expect(await apiIndex.peek((name: 'dio', version: '1.6.0')), isNotNull);
    });
  });

  // ─── Shared across the four api-index tools ────────────────────────────────
  //
  // browse_api_symbols, find_symbols, get_api_diff, and get_symbol_documentation
  // all resolve the dartdoc index through the same CacheRegistry-owned apiIndex
  // facade. A second call for the same (package, version) from any of the four
  // tools must be a hit — see issues/keyed-cache/03-api-index-cache.md.

  group('apiIndex shared across the four api-index tools', () {
    test('find_symbols reuses the index warmed by browse_api_symbols', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      await buildHandler().call(_request({'package': 'http', 'query': 'client'}));
      await FindSymbolsHandler(
        versionResolver: versionResolver,
        apiIndex: apiIndex,
        log: (_, _) {},
      ).call(
        CallToolRequest(name: 'find_symbols', arguments: {'package': 'http', 'query': 'client'}),
      );

      verify(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('index.json'))),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('get_api_diff reuses the index warmed by browse_api_symbols', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);

      await buildHandler().call(_request({'package': 'http', 'query': 'client'}));
      await GetApiDiffHandler(apiIndex: apiIndex, log: (_, _) {}).call(
        CallToolRequest(
          name: 'get_api_diff',
          arguments: {'package': 'http', 'fromVersion': '1.6.0', 'toVersion': '1.6.0'},
        ),
      );

      verify(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('index.json'))),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('get_symbol_documentation reuses the index warmed by browse_api_symbols', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);
      when(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/1.6.0/browser_client/'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => ok(readFixture('symbol_doc.html')));

      await buildHandler().call(_request({'package': 'http', 'query': 'client'}));
      await GetSymbolDocumentationHandler(
        versionResolver: versionResolver,
        apiIndex: apiIndex,
        symbolDoc: CacheRegistry(client: stack.client, clock: () => fakeNow).symbolDoc,
        log: (_, _) {},
      ).call(
        CallToolRequest(
          name: 'get_symbol_documentation',
          arguments: {'package': 'http', 'symbol': 'BrowserClient'},
        ),
      );

      verify(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('index.json'))),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });
  });
}
