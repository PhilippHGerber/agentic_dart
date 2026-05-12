/// Unit tests for [SearchPackagesHandler].
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:pubdev_context/src/cache/memory_cache.dart';
import 'package:pubdev_context/src/data/models.dart';
import 'package:pubdev_context/src/data/pub_client.dart';
import 'package:pubdev_context/src/tools/search_packages.dart';
import 'package:test/test.dart';

// ─── Mocks ────────────────────────────────────────────────────────────────────

class _MockHttpClient extends Mock implements http.Client {}

// ─── Helpers ──────────────────────────────────────────────────────────────────

String _readFixture(String name) => File('test/fixtures/$name').readAsStringSync();

http.Response _ok(String body) => http.Response(body, 200);

RetryPolicy get _instant => RetryPolicy(delay: (_) async {});

void _stubUrl({
  required _MockHttpClient mock,
  required String urlFragment,
  required http.Response response,
}) {
  when(
    () => mock.get(
      any(that: predicate<Uri>((u) => u.toString().contains(urlFragment))),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer((_) async => response);
}

/// Stubs the three endpoints needed for a single-result search.
///
/// `/api/search` returns one entry (`http`), then `/api/packages/http` and
/// `/api/packages/http/score` return the test fixtures.
void _stubSingleResult(_MockHttpClient mock) {
  _stubUrl(
    mock: mock,
    urlFragment: '/api/search',
    response: _ok('{"packages":[{"package":"http"}]}'),
  );
  // Register the less-specific stub first so the more-specific /score stub
  // wins (mocktail resolves stubs LIFO — last registered takes priority).
  _stubUrl(
    mock: mock,
    urlFragment: '/api/packages/http',
    response: _ok(_readFixture('package_info.json')),
  );
  _stubUrl(
    mock: mock,
    urlFragment: '/api/packages/http/score',
    response: _ok(_readFixture('package_score.json')),
  );
}

/// Creates a [CallToolRequest] for `search_packages` with the given [args].
CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'search_packages', arguments: args);

/// Decodes the first content item of [result] as a JSON list of summaries.
List<Map<String, Object?>> _summaries(CallToolResult result) =>
    (jsonDecode((result.content.first as TextContent).text) as List<Object?>)
        .cast<Map<String, Object?>>()
        .toList();

/// Decodes the first content item of [result] as a JSON error payload.
Map<String, Object?> _errorPayload(CallToolResult result) =>
    jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late _MockHttpClient mockHttp;
  late PubDevClient client;
  late DateTime fakeNow;
  late ResponseCache<List<PackageSummary>> cache;
  final loggedMessages = <(LoggingLevel, Object)>[];

  SearchPackagesHandler buildHandler() => SearchPackagesHandler(
    client: client,
    cache: cache,
    log: (level, data) => loggedMessages.add((level, data)),
  );

  setUp(() {
    mockHttp = _MockHttpClient();
    registerFallbackValue(Uri.parse('https://pub.dev'));
    client = PubDevClient(httpClient: mockHttp, retryPolicy: _instant);
    fakeNow = DateTime(2025, 5, 10);
    cache = ResponseCache(clock: () => fakeNow);
    loggedMessages.clear();
  });

  tearDown(() => client.close());

  // ─── Limit validation ───────────────────────────────────────────────────────

  group('limit greater than 20', () {
    test('returns invalid_input domain error without calling the HTTP client', () async {
      final result = await buildHandler().call(_request({'query': 'http', 'limit': 21}));

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['error'], equals('invalid_input'));
      verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
    });

    test('error payload contains a suggestion', () async {
      final result = await buildHandler().call(_request({'query': 'http', 'limit': 21}));

      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  // ─── Cache hit ──────────────────────────────────────────────────────────────

  group('cache hit', () {
    test('returns the cached result without issuing a second HTTP request', () async {
      _stubSingleResult(mockHttp);
      final handler = buildHandler();

      await handler.call(_request({'query': 'http'}));
      fakeNow = fakeNow.add(const Duration(minutes: 4));
      await handler.call(_request({'query': 'http'}));

      verify(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('/api/search'))),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('logs a debug cache-hit message', () async {
      _stubSingleResult(mockHttp);
      final handler = buildHandler();

      await handler.call(_request({'query': 'http'}));
      fakeNow = fakeNow.add(const Duration(minutes: 4));
      await handler.call(_request({'query': 'http'}));

      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString());
      expect(debugLogs.any((m) => m.contains('cache hit')), isTrue);
    });
  });

  // ─── Cache miss ─────────────────────────────────────────────────────────────

  group('cache miss', () {
    test('logs a debug cache-miss message', () async {
      _stubSingleResult(mockHttp);

      await buildHandler().call(_request({'query': 'http'}));

      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString());
      expect(debugLogs.any((m) => m.contains('cache miss')), isTrue);
    });

    test('logs an info message containing the query', () async {
      _stubSingleResult(mockHttp);

      await buildHandler().call(_request({'query': 'http'}));

      final infoLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.info)
          .map((m) => m.$2.toString());
      expect(infoLogs.any((m) => m.contains('query=http')), isTrue);
    });
  });

  // ─── Successful search ──────────────────────────────────────────────────────

  group('successful search', () {
    test('returns a JSON array with one PackageSummary entry', () async {
      _stubSingleResult(mockHttp);

      final result = await buildHandler().call(_request({'query': 'http'}));

      expect(result.isError, isNull);
      expect(_summaries(result), hasLength(1));
    });

    test('result contains activeMaintenance field', () async {
      _stubSingleResult(mockHttp);

      final result = await buildHandler().call(_request({'query': 'http'}));

      expect(_summaries(result).first, contains('activeMaintenance'));
    });

    test('result contains daysSinceUpdate field', () async {
      _stubSingleResult(mockHttp);

      final result = await buildHandler().call(_request({'query': 'http'}));

      expect(_summaries(result).first, contains('daysSinceUpdate'));
    });

    test('result contains publisher for a verified publisher package', () async {
      _stubSingleResult(mockHttp);

      final result = await buildHandler().call(_request({'query': 'http'}));

      expect(_summaries(result).first['publisher'], equals('dart.dev'));
    });

    test('result contains license when score tags include a license tag', () async {
      _stubSingleResult(mockHttp);

      final result = await buildHandler().call(_request({'query': 'http'}));

      expect(_summaries(result).first['license'], isNotNull);
    });

    test('result omits publisher when package has no verified publisher', () async {
      final scoreNoPublisher = jsonEncode({
        'grantedPoints': 80,
        'maxPoints': 160,
        'likeCount': 100,
        'downloadCount30Days': 5000,
        'tags': ['sdk:dart', 'platform:web'],
      });
      _stubUrl(
        mock: mockHttp,
        urlFragment: '/api/search',
        response: _ok('{"packages":[{"package":"http"}]}'),
      );
      _stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http/score',
        response: _ok(scoreNoPublisher),
      );
      _stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http',
        response: _ok(_readFixture('package_info.json')),
      );

      final result = await buildHandler().call(_request({'query': 'http'}));

      expect(_summaries(result).first.containsKey('publisher'), isFalse);
    });
  });

  // ─── Client failure ─────────────────────────────────────────────────────────

  group('client failure', () {
    test('returns a domain error when the search endpoint returns HTTP 404', () async {
      _stubUrl(
        mock: mockHttp,
        urlFragment: '/api/search',
        response: http.Response('{}', 404),
      );

      final result = await buildHandler().call(_request({'query': 'missing'}));

      expect(result.isError, isTrue);
      expect(_errorPayload(result), contains('error'));
      expect(_errorPayload(result), contains('message'));
      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  // ─── SDK filter ─────────────────────────────────────────────────────────────

  group('sdk filter', () {
    test('passes sdk parameter to the pub.dev search URL', () async {
      _stubSingleResult(mockHttp);

      await buildHandler().call(_request({'query': 'json', 'sdk': 'flutter'}));

      verify(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.queryParameters['sdk'] == 'flutter')),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });
  });

  // ─── Platform filter ────────────────────────────────────────────────────────

  group('platform filter', () {
    test('passes platform parameter to the pub.dev search URL', () async {
      _stubSingleResult(mockHttp);

      await buildHandler().call(_request({'query': 'json', 'platform': 'web'}));

      verify(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.queryParameters['platform'] == 'web')),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });
  });

  // ─── Sort mapping ───────────────────────────────────────────────────────────

  group('sort mapping', () {
    test('maps likes sort to the "like" query parameter', () async {
      _stubSingleResult(mockHttp);

      await buildHandler().call(_request({'query': 'json', 'sort': 'likes'}));

      verify(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.queryParameters['sort'] == 'like')),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('maps pub_points sort to the "points" query parameter', () async {
      _stubSingleResult(mockHttp);

      await buildHandler().call(_request({'query': 'json', 'sort': 'pub_points'}));

      verify(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.queryParameters['sort'] == 'points')),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('maps updated sort to the "recent" query parameter', () async {
      _stubSingleResult(mockHttp);

      await buildHandler().call(_request({'query': 'json', 'sort': 'updated'}));

      verify(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.queryParameters['sort'] == 'recent')),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('omits sort parameter when sort is relevance', () async {
      _stubSingleResult(mockHttp);

      await buildHandler().call(_request({'query': 'json', 'sort': 'relevance'}));

      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/api/search') && !u.queryParameters.containsKey('sort'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });
  });

  // ─── Default parameters ──────────────────────────────────────────────────────

  group('default limit', () {
    test('returns at most 5 results when no limit is supplied', () async {
      final sixPackages = List.generate(6, (i) => '{"package":"pkg$i"}').join(',');
      _stubUrl(
        mock: mockHttp,
        urlFragment: '/api/search',
        response: _ok('{"packages":[$sixPackages]}'),
      );
      _stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/',
        response: _ok(_readFixture('package_info.json')),
      );
      _stubUrl(
        mock: mockHttp,
        urlFragment: '/score',
        response: _ok(_readFixture('package_score.json')),
      );

      final result = await buildHandler().call(_request({'query': 'pkg'}));

      expect(_summaries(result).length, lessThanOrEqualTo(5));
    });
  });
}
