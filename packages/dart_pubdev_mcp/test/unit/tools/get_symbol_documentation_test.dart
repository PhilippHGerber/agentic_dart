/// Unit tests for [GetSymbolDocumentationHandler].
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:dart_pubdev_mcp/src/cache/cache_registry.dart';
import 'package:dart_pubdev_mcp/src/data/domain_error.dart';
import 'package:dart_pubdev_mcp/src/data/models.dart';
import 'package:dart_pubdev_mcp/src/tools/get_symbol_documentation.dart';
import 'package:dart_pubdev_mcp/src/tools/tool_definitions.dart' show getSymbolDocumentationTool;
import 'package:dart_pubdev_mcp/src/tools/version_resolver.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';
import '../../support/pub_stubs.dart';
import '../../support/schema_conformance.dart';

// ─── HTTP stub helpers ─────────────────────────────────────────────────────────

/// Stubs `GET /documentation/<package>/<version>/<href>`.
///
/// [version] defaults to `'1.6.0'` — matching the resolved stable version.
void _stubSymbolDoc(
  MockHttpClient mock, {
  required String href,
  int statusCode = 200,
  String packageName = 'http',
  String version = '1.6.0',
}) {
  when(
    () => mock.get(
      any(
        that: predicate<Uri>(
          (u) => u.toString().contains('/documentation/$packageName/$version/$href'),
        ),
      ),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer(
    (_) async => statusCode == 200
        ? ok(readFixture('symbol_doc.html'))
        : http.Response('Not Found', statusCode),
  );
}

/// Maps a [DartdocSymbol.type] string back to its raw dartdoc `kind` int — the
/// inverse of [DartdocSymbol.fromJson]'s kind→type mapping — so tests can
/// serialise a hand-built symbol list into a synthetic `index.json` HTTP stub
/// body instead of pre-seeding the (now-private) apiIndex cache store.
int _kindFor(String type) => switch (type) {
  'class' => 3,
  'constructor' => 2,
  'library' => 9,
  'method' => 10,
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

// ─── Test symbol helpers ───────────────────────────────────────────────────────

/// Creates a minimal [DartdocSymbol] for test use.
DartdocSymbol _sym({
  required String name,
  required String qualifiedName,
  required String href,
  String type = 'method',
  String desc = '',
}) => DartdocSymbol(
  name: name,
  qualifiedName: qualifiedName,
  href: href,
  type: type,
  desc: desc,
);

/// A [DartdocSymbol] for `Client` (class, in the http library).
final DartdocSymbol _clientClass = _sym(
  name: 'Client',
  qualifiedName: 'http.Client',
  href: 'http/Client-class.html',
  type: 'class',
);

/// A [DartdocSymbol] for `Client.send` (method).
final DartdocSymbol _clientSend = _sym(
  name: 'send',
  qualifiedName: 'http.Client.send',
  href: 'http/Client/send.html',
);

// ─── Request / result helpers ──────────────────────────────────────────────────

/// Creates a [CallToolRequest] for `get_symbol_documentation` with the given [args].
CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'get_symbol_documentation', arguments: args);

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

/// Extracts the `documentation` field from the success JSON object.
///
/// The handler wraps the symbol documentation text in a JSON object:
/// `{"resolvedVersion": "...", "documentation": "..."}`.
String _text(CallToolResult result) {
  final json = jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;
  return (json['documentation'] as String?) ?? '';
}

/// Extracts the `resolvedVersion` field from the success JSON object.
String? _resolvedVersion(CallToolResult result) {
  final json = jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;
  return json['resolvedVersion'] as String?;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late TestStack stack;
  late MockHttpClient mockHttp;
  late VersionResolver versionResolver;
  late DateTime fakeNow;
  late CacheRegistry registry;
  final loggedMessages = <(LoggingLevel, Object)>[];

  GetSymbolDocumentationHandler buildHandler() => GetSymbolDocumentationHandler(
    versionResolver: versionResolver,
    apiIndex: registry.apiIndex,
    symbolDoc: registry.symbolDoc,
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
    registry = stack.caches;
    loggedMessages.clear();
  });

  tearDown(() => stack.close());

  // ─── Pass 1: exact name match ───────────────────────────────────────────────

  group('pass 1 — exact name match', () {
    test('resolves a single exact name match and returns documentation', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass]));
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(result.isError, isNull);
      expect(_text(result), isNotEmpty);
    });

    test('returns non-empty plain-text content on a pass 1 hit', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass]));
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(_text(result), isNotEmpty);
    });

    test('makes exactly one HTTP request for the symbol doc on a pass 1 hit', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass]));
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      await buildHandler().call(_request({'package': 'http', 'symbol': 'Client'}));

      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/1.6.0/http/Client-class.html'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });
  });

  // ─── Pass 2: qualifiedName suffix match ─────────────────────────────────────

  group('pass 2 — qualifiedName suffix match', () {
    test('resolves "Client.send" via suffix match to the method href', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass, _clientSend]));
      _stubSymbolDoc(mockHttp, href: 'http/Client/send.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client.send'}),
      );

      expect(result.isError, isNull);
      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/1.6.0/http/Client/send.html'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('ignores symbols whose qualifiedName has no dot separator in pass 2', () async {
      stubPackageInfo(mockHttp);
      final library = _sym(
        name: 'http',
        qualifiedName: 'http', // no dot — must not match anything
        href: 'http/',
        type: 'library',
      );
      stubIndexJson(mockHttp, body: _indexJsonBody([library, _clientSend]));
      _stubSymbolDoc(mockHttp, href: 'http/Client/send.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client.send'}),
      );

      // Should resolve to _clientSend via suffix match, not error.
      expect(result.isError, isNull);
    });
  });

  // ─── Pass 0: exact qualifiedName match (ambiguous_symbol retry path) ──────────

  group('pass 0 — exact qualifiedName match', () {
    test('resolves "http.Client" to the class href (retry after ambiguous_symbol)', () async {
      stubPackageInfo(mockHttp);
      final classA = _sym(
        name: 'Client',
        qualifiedName: 'http.Client',
        href: 'http/Client-class.html',
        type: 'class',
      );
      final classB = _sym(
        name: 'Client',
        qualifiedName: 'browser_client.Client',
        href: 'browser_client/Client-class.html',
        type: 'class',
      );
      stubIndexJson(mockHttp, body: _indexJsonBody([classA, classB]));
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      // First call returns ambiguous_symbol; simulated retry passes the
      // qualifiedName directly.
      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'http.Client'}),
      );

      expect(result.isError, isNull);
      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('http/Client-class.html'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('resolves "browser_client.Client" to the correct href', () async {
      stubPackageInfo(mockHttp);
      final classA = _sym(
        name: 'Client',
        qualifiedName: 'http.Client',
        href: 'http/Client-class.html',
        type: 'class',
      );
      final classB = _sym(
        name: 'Client',
        qualifiedName: 'browser_client.Client',
        href: 'browser_client/Client-class.html',
        type: 'class',
      );
      stubIndexJson(mockHttp, body: _indexJsonBody([classA, classB]));
      _stubSymbolDoc(mockHttp, href: 'browser_client/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'browser_client.Client'}),
      );

      expect(result.isError, isNull);
      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('browser_client/Client-class.html'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('pass 0 takes priority over pass 1 for the same symbol', () async {
      stubPackageInfo(mockHttp);
      // qualifiedName 'http.Client' would also match pass 1 (name == 'Client'
      // for a different entry) — pass 0 should resolve it first and unambiguously.
      final classA = _sym(
        name: 'Client',
        qualifiedName: 'http.Client',
        href: 'http/Client-class.html',
        type: 'class',
      );
      final classB = _sym(
        name: 'Client',
        qualifiedName: 'browser_client.Client',
        href: 'browser_client/Client-class.html',
        type: 'class',
      );
      stubIndexJson(mockHttp, body: _indexJsonBody([classA, classB]));
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      // 'http.Client' has an exact qualifiedName match — must resolve without
      // going to pass 1 (which would see two 'Client' name matches and
      // return ambiguous_symbol).
      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'http.Client'}),
      );

      expect(result.isError, isNull);
    });

    test('end-to-end ambiguous_symbol retry succeeds', () async {
      stubPackageInfo(mockHttp);
      final classA = _sym(
        name: 'Client',
        qualifiedName: 'http.Client',
        href: 'http/Client-class.html',
        type: 'class',
      );
      final classB = _sym(
        name: 'Client',
        qualifiedName: 'browser_client.Client',
        href: 'browser_client/Client-class.html',
        type: 'class',
      );
      stubIndexJson(mockHttp, body: _indexJsonBody([classA, classB]));

      final handler = buildHandler();

      // Initial call — ambiguous.
      final first = await handler.call(_request({'package': 'http', 'symbol': 'Client'}));
      expect(first.isError, isTrue);
      expect(_errorPayload(first)['code'], equals(DomainErrors.ambiguousSymbol));

      // Pick the first candidate and retry.
      final retrySymbol = _candidates(_errorPayload(first)).first;

      final expectedHref = retrySymbol == 'http.Client'
          ? 'http/Client-class.html'
          : 'browser_client/Client-class.html';
      _stubSymbolDoc(mockHttp, href: expectedHref);

      final second = await handler.call(
        _request({'package': 'http', 'symbol': retrySymbol}),
      );

      expect(second.isError, isNull);
    });
  });

  // ─── Disambiguation ─────────────────────────────────────────────────────────

  group('disambiguation', () {
    test('prefers the sole class entry when multiple name matches exist', () async {
      stubPackageInfo(mockHttp);
      final closeMethod = _sym(
        name: 'Client',
        qualifiedName: 'http.Client.Client',
        href: 'http/Client/Client.html',
        type: 'constructor',
      );
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass, closeMethod]));
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(result.isError, isNull);
      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('http/Client-class.html'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('returns ambiguous_symbol when multiple class entries match', () async {
      stubPackageInfo(mockHttp);
      final classA = _sym(
        name: 'Client',
        qualifiedName: 'http.Client',
        href: 'http/Client-class.html',
        type: 'class',
      );
      final classB = _sym(
        name: 'Client',
        qualifiedName: 'browser_client.Client',
        href: 'browser_client/Client-class.html',
        type: 'class',
      );
      stubIndexJson(mockHttp, body: _indexJsonBody([classA, classB]));

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.ambiguousSymbol));
    });

    test('ambiguous_symbol payload includes candidates list in details', () async {
      stubPackageInfo(mockHttp);
      final classA = _sym(
        name: 'Client',
        qualifiedName: 'http.Client',
        href: 'http/Client-class.html',
        type: 'class',
      );
      final classB = _sym(
        name: 'Client',
        qualifiedName: 'browser_client.Client',
        href: 'browser_client/Client-class.html',
        type: 'class',
      );
      stubIndexJson(mockHttp, body: _indexJsonBody([classA, classB]));

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      final candidates = _candidates(_errorPayload(result));
      expect(candidates, isA<List<String>>());
      expect(candidates, containsAll(['http.Client', 'browser_client.Client']));
    });

    test('returns ambiguous_symbol when multiple matches have no class entry', () async {
      stubPackageInfo(mockHttp);
      final methodA = _sym(
        name: 'close',
        qualifiedName: 'http.Client.close',
        href: 'http/Client/close.html',
      );
      final methodB = _sym(
        name: 'close',
        qualifiedName: 'browser_client.BrowserClient.close',
        href: 'browser_client/BrowserClient/close.html',
      );
      stubIndexJson(mockHttp, body: _indexJsonBody([methodA, methodB]));

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'close'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.ambiguousSymbol));
    });

    test('ambiguous_symbol payload contains message and suggestion', () async {
      stubPackageInfo(mockHttp);
      final classA = _sym(
        name: 'Client',
        qualifiedName: 'http.Client',
        href: 'http/Client-class.html',
        type: 'class',
      );
      final classB = _sym(
        name: 'Client',
        qualifiedName: 'browser_client.Client',
        href: 'browser_client/Client-class.html',
        type: 'class',
      );
      stubIndexJson(mockHttp, body: _indexJsonBody([classA, classB]));

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(_errorPayload(result), contains('message'));
      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  // ─── symbol_not_found ───────────────────────────────────────────────────────

  group('symbol_not_found', () {
    test('returns symbol_not_found when symbol is absent from the index', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass]));

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'NonExistentSymbol'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
    });

    test('returns symbol_not_found when the resolved href returns HTTP 404', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass]));
      _stubSymbolDoc(mockHttp, statusCode: 404, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.symbolNotFound));
    });

    test('symbol_not_found payload contains message and suggestion', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass]));
      _stubSymbolDoc(mockHttp, statusCode: 404, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(_errorPayload(result), contains('message'));
      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  // ─── no_documentation ───────────────────────────────────────────────────────

  group('no_documentation', () {
    test('returns no_documentation when the API index is empty', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody(const <DartdocSymbol>[]));

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.noDocumentation));
    });

    test('returns no_documentation when the index endpoint returns 404', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, statusCode: 404);

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.noDocumentation));
    });
  });

  // ─── Resolve failure (P1.16) ─────────────────────────────────────────────────
  //
  // When `version` is omitted the handler resolves the latest stable version
  // first. A failed resolution (404) must propagate as package_not_found —
  // distinct from the no_documentation mapping applied to index-fetch 404s —
  // and must short-circuit before any index fetch.

  group('resolve failure (version omitted)', () {
    /// Stubs `GET /api/packages/missing` (the resolve endpoint) to return 404.
    void stubResolve404() {
      when(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) =>
                  u.toString().contains('/api/packages/missing') &&
                  !u.toString().contains('/score') &&
                  !u.toString().contains('/versions/'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => http.Response('Not Found', 404));
    }

    test('propagates package_not_found when resolution returns 404', () async {
      stubResolve404();

      final result = await buildHandler().call(
        _request({'package': 'missing', 'symbol': 'Client'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));
    });

    test('does not fetch the API index when resolution fails', () async {
      stubResolve404();

      await buildHandler().call(_request({'package': 'missing', 'symbol': 'Client'}));

      verifyNever(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('index.json'))),
          headers: any(named: 'headers'),
        ),
      );
    });
  });

  // ─── Index cache behavior ───────────────────────────────────────────────────

  group('API index cache', () {
    test('a second call is an index cache hit issuing no further HTTP request', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass]));
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');
      final handler = buildHandler();

      await handler.call(_request({'package': 'http', 'symbol': 'Client'}));
      fakeNow = fakeNow.add(const Duration(minutes: 30));
      await handler.call(_request({'package': 'http', 'symbol': 'Client'}));

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

  // ─── Symbol doc cache behavior ──────────────────────────────────────────────

  group('symbol doc cache', () {
    test('issues only one doc HTTP request for two calls resolving to the same href', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass]));
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');
      final handler = buildHandler();

      await handler.call(_request({'package': 'http', 'symbol': 'Client'}));
      fakeNow = fakeNow.add(const Duration(minutes: 30));
      await handler.call(_request({'package': 'http', 'symbol': 'Client'}));

      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/1.6.0/http/Client-class.html'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('warms the symbolDoc facade entry for (package, version, href)', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass]));
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      await buildHandler().call(_request({'package': 'http', 'symbol': 'Client'}));

      expect(
        await registry.symbolDoc.peek((
          package: 'http',
          version: '1.6.0',
          href: 'http/Client-class.html',
        )),
        isNotNull,
      );
    });
  });

  // ─── Symbol doc cache — version isolation ──────────────────────────────────

  group('symbol doc cache — version isolation', () {
    test('pinned-version request populates a separate cache entry from resolved', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass]));
      stubIndexJson(mockHttp, version: '1.0.0', body: _indexJsonBody([_clientClass]));
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html', version: '1.0.0');
      final handler = buildHandler();

      await handler.call(_request({'package': 'http', 'symbol': 'Client'}));
      await handler.call(
        _request({'package': 'http', 'symbol': 'Client', 'version': '1.0.0'}),
      );

      expect(
        await registry.symbolDoc.peek((
          package: 'http',
          version: '1.6.0',
          href: 'http/Client-class.html',
        )),
        isNotNull,
      );
      expect(
        await registry.symbolDoc.peek((
          package: 'http',
          version: '1.0.0',
          href: 'http/Client-class.html',
        )),
        isNotNull,
      );
    });

    test('different versions issue separate HTTP doc requests', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass]));
      stubIndexJson(mockHttp, version: '1.0.0', body: _indexJsonBody([_clientClass]));
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html', version: '1.0.0');
      final handler = buildHandler();

      await handler.call(_request({'package': 'http', 'symbol': 'Client'}));
      await handler.call(
        _request({'package': 'http', 'symbol': 'Client', 'version': '1.0.0'}),
      );

      // Both versions must have triggered a distinct HTTP request.
      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/1.6.0/http/Client-class.html'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/1.0.0/http/Client-class.html'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });
  });

  // ─── Cache poisoning on transient failure (P0.4) ────────────────────────────
  //
  // A single transient failure (429/503/network) must not be stored as an empty
  // result for the full TTL. A second call must retry the fetch and succeed.

  group('transient failure must not poison the cache (P0.4)', () {
    test('a transient index 503 is not cached — a second call retries and succeeds', () async {
      stubPackageInfo(mockHttp);
      // The index endpoint fails with 503 during the first handler call (the
      // client exhausts its retries), then recovers for the second call.
      var indexHealthy = false;
      when(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/1.6.0/index.json'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer(
        (_) async => indexHealthy
            ? ok(readFixture('index_json.json'))
            : http.Response('Service Unavailable', 503),
      );
      _stubSymbolDoc(mockHttp, href: 'browser_client/BrowserClient-class.html');
      final handler = buildHandler();

      // First call surfaces the transient failure.
      final first = await handler.call(
        _request({'package': 'http', 'symbol': 'BrowserClient'}),
      );
      expect(first.isError, isTrue);
      expect(_errorPayload(first)['code'], equals(DomainErrors.serviceUnavailable));

      // The outage clears; the second call retries the fetch and succeeds —
      // proving the failure was not cached.
      indexHealthy = true;
      final second = await handler.call(
        _request({'package': 'http', 'symbol': 'BrowserClient'}),
      );
      expect(second.isError, isNull);
    });

    test('a transient index 429 is not cached — a second call retries and succeeds', () async {
      stubPackageInfo(mockHttp);
      // The index endpoint is rate-limited (429) during the first handler call,
      // then recovers for the second call.
      var indexHealthy = false;
      when(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/1.6.0/index.json'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer(
        (_) async => indexHealthy
            ? ok(readFixture('index_json.json'))
            : http.Response('Too Many Requests', 429),
      );
      _stubSymbolDoc(mockHttp, href: 'browser_client/BrowserClient-class.html');
      final handler = buildHandler();

      // First call surfaces the rate-limit failure.
      final first = await handler.call(
        _request({'package': 'http', 'symbol': 'BrowserClient'}),
      );
      expect(first.isError, isTrue);
      expect(_errorPayload(first)['code'], equals(DomainErrors.rateLimited));

      // The rate limit clears; the second call retries the fetch and succeeds —
      // proving the failure was not cached.
      indexHealthy = true;
      final second = await handler.call(
        _request({'package': 'http', 'symbol': 'BrowserClient'}),
      );
      expect(second.isError, isNull);
    });

    test('a transient doc 503 is not cached — a second call retries and succeeds', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass]));
      // The symbol-doc endpoint fails with 503 during the first handler call,
      // then recovers for the second call.
      var docHealthy = false;
      when(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/1.6.0/http/Client-class.html'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer(
        (_) async => docHealthy
            ? ok(readFixture('symbol_doc.html'))
            : http.Response('Service Unavailable', 503),
      );
      final handler = buildHandler();

      // First call surfaces the transient failure.
      final first = await handler.call(_request({'package': 'http', 'symbol': 'Client'}));
      expect(first.isError, isTrue);
      expect(_errorPayload(first)['code'], equals(DomainErrors.serviceUnavailable));

      // The failure must NOT have populated the symbol-doc cache.
      expect(
        await registry.symbolDoc.peek((
          package: 'http',
          version: '1.6.0',
          href: 'http/Client-class.html',
        )),
        isNull,
      );

      // The outage clears; the second call retries the fetch and succeeds.
      docHealthy = true;
      final second = await handler.call(_request({'package': 'http', 'symbol': 'Client'}));
      expect(second.isError, isNull);
      expect(_text(second), isNotEmpty);
    });

    test('a transient doc 429 is not cached — a second call retries and succeeds', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass]));
      // The symbol-doc endpoint is rate-limited (429) during the first handler
      // call, then recovers for the second call.
      var docHealthy = false;
      when(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/1.6.0/http/Client-class.html'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer(
        (_) async => docHealthy
            ? ok(readFixture('symbol_doc.html'))
            : http.Response('Too Many Requests', 429),
      );
      final handler = buildHandler();

      // First call surfaces the rate-limit failure.
      final first = await handler.call(_request({'package': 'http', 'symbol': 'Client'}));
      expect(first.isError, isTrue);
      expect(_errorPayload(first)['code'], equals(DomainErrors.rateLimited));

      // The failure must NOT have populated the symbol-doc cache.
      expect(
        await registry.symbolDoc.peek((
          package: 'http',
          version: '1.6.0',
          href: 'http/Client-class.html',
        )),
        isNull,
      );

      // The rate limit clears; the second call retries the fetch and succeeds.
      docHealthy = true;
      final second = await handler.call(_request({'package': 'http', 'symbol': 'Client'}));
      expect(second.isError, isNull);
      expect(_text(second), isNotEmpty);
    });
  });

  // ─── Client failures ────────────────────────────────────────────────────────

  group('client failure (doc fetch)', () {
    test('propagates rate_limited when the symbol doc page returns HTTP 429', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass]));
      _stubSymbolDoc(mockHttp, statusCode: 429, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.rateLimited));
    });

    test('propagates service_unavailable when the symbol doc page returns HTTP 503', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass]));
      _stubSymbolDoc(mockHttp, statusCode: 503, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.serviceUnavailable));
    });

    test('error payload always contains message and suggestion fields', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass]));
      _stubSymbolDoc(mockHttp, statusCode: 503, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(_errorPayload(result), contains('message'));
      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  // ─── version parameter ──────────────────────────────────────────────────────

  group('version parameter', () {
    test('uses the specified version in the index URL', () async {
      stubIndexJson(mockHttp, version: '1.2.0');
      _stubSymbolDoc(mockHttp, href: 'browser_client/BrowserClient-class.html', version: '1.2.0');

      await buildHandler().call(
        _request({'package': 'http', 'symbol': 'BrowserClient', 'version': '1.2.0'}),
      );

      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/1.2.0/index.json'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('uses the specified version in the symbol doc URL', () async {
      stubIndexJson(mockHttp, version: '1.2.0');
      _stubSymbolDoc(mockHttp, href: 'browser_client/BrowserClient-class.html', version: '1.2.0');

      await buildHandler().call(
        _request({'package': 'http', 'symbol': 'BrowserClient', 'version': '1.2.0'}),
      );

      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) =>
                  u.toString().contains('/documentation/http/1.2.0/') &&
                  u.toString().contains('BrowserClient'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(greaterThanOrEqualTo(1));
    });

    test('a pinned version does not reuse the resolved-latest index cache entry', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, version: '1.2.0');
      stubIndexJson(mockHttp);
      _stubSymbolDoc(mockHttp, href: 'browser_client/BrowserClient-class.html', version: '1.2.0');
      _stubSymbolDoc(mockHttp, href: 'browser_client/BrowserClient-class.html');
      final handler = buildHandler();

      await handler.call(
        _request({'package': 'http', 'symbol': 'BrowserClient', 'version': '1.2.0'}),
      );
      await handler.call(_request({'package': 'http', 'symbol': 'BrowserClient'}));

      // Both the pinned 1.2.0 index and the resolved-latest 1.6.0 index were
      // fetched independently — a pinned version never reuses the latest entry.
      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/documentation/http/1.2.0/index.json'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
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

    test('omitting version resolves to latest stable version', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp);
      _stubSymbolDoc(mockHttp, href: 'browser_client/BrowserClient-class.html');

      await buildHandler().call(
        _request({'package': 'http', 'symbol': 'BrowserClient'}),
      );

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

  // ─── resolvedVersion (P1.13) ──────────────────────────────────────────────────

  group('resolvedVersion', () {
    test('equals the resolved latest stable version when version is omitted', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass]));
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(_resolvedVersion(result), equals('1.6.0'));
    });

    test('echoes the supplied version on a pinned request', () async {
      stubIndexJson(mockHttp, version: '1.2.0', body: _indexJsonBody([_clientClass]));
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html', version: '1.2.0');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client', 'version': '1.2.0'}),
      );

      expect(_resolvedVersion(result), equals('1.2.0'));
    });

    test('echoes package and symbol and conforms to outputSchema', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass]));
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      final json = jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;
      expect(json['package'], equals('http'));
      expect(json['symbol'], equals('Client'));
      expectConformsToOutputSchema(getSymbolDocumentationTool, result.structuredContent);
    });
  });

  // ─── HTML processing ─────────────────────────────────────────────────────────

  group('HTML processing', () {
    test('strips HTML tags from the returned content', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass]));
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(_text(result), isNot(contains('<html')));
      expect(_text(result), isNot(contains('<body')));
    });

    test('decodes HTML entities in the returned content', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass]));
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      // Fixture contains &lt; and &gt; — these should be decoded to < and >.
      expect(_text(result), contains('<'));
      expect(_text(result), contains('>'));
    });

    test('result contains recognisable symbol content from the fixture', () async {
      stubPackageInfo(mockHttp);
      stubIndexJson(mockHttp, body: _indexJsonBody([_clientClass]));
      _stubSymbolDoc(mockHttp, href: 'http/Client-class.html');

      final result = await buildHandler().call(
        _request({'package': 'http', 'symbol': 'Client'}),
      );

      expect(_text(result), contains('Client'));
    });
  });
}
