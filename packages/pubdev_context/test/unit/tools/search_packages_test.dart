/// Unit tests for [SearchPackagesHandler].
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:pubdev_context/src/cache/cache_registry.dart';
import 'package:pubdev_context/src/tools/search_packages.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';

// ─── Helpers ──────────────────────────────────────────────────────────────────

/// Stubs the three endpoints needed for a single-result search.
///
/// `/api/search` returns one entry (`http`), then `/api/packages/http` and
/// `/api/packages/http/score` return the test fixtures.
void _stubSingleResult(MockHttpClient mock) {
  stubUrl(
    mock: mock,
    urlFragment: '/api/search',
    response: ok('{"packages":[{"package":"http"}]}'),
  );
  // Register the less-specific stub first so the more-specific /score stub
  // wins (see stubUrl for why order matters).
  stubUrl(
    mock: mock,
    urlFragment: '/api/packages/http',
    response: ok(readFixture('package_info.json')),
  );
  stubUrl(
    mock: mock,
    urlFragment: '/api/packages/http/score',
    response: ok(readFixture('package_score.json')),
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
  late DateTime fakeNow;
  late CacheRegistry registry;
  final loggedMessages = <(LoggingLevel, Object)>[];

  SearchPackagesHandler buildHandler() => SearchPackagesHandler(
    searchResults: registry.searchResults,
    log: (level, data) => loggedMessages.add((level, data)),
  );

  setUp(() {
    fakeNow = DateTime(2025, 5, 10);
    stack = TestStack(clock: () => fakeNow);
    mockHttp = stack.http;
    registry = stack.caches;
    loggedMessages.clear();
  });

  tearDown(() => stack.close());

  // Limit validation (limit > 20) moved to server-owned schema validation
  // (ADR-0006, ticket 02) — see test/unit/pub_mcp_test.dart's
  // 'argument validation' group. The handler no longer checks `limit` itself.

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
  });

  // ─── Cache miss ─────────────────────────────────────────────────────────────

  group('cache miss', () {
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
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/search',
        response: ok('{"packages":[{"package":"http"}]}'),
      );
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http/score',
        response: ok(scoreNoPublisher),
      );
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http',
        response: ok(readFixture('package_info.json')),
      );

      final result = await buildHandler().call(_request({'query': 'http'}));

      expect(_summaries(result).first.containsKey('publisher'), isFalse);
    });
  });

  // ─── Client failure ─────────────────────────────────────────────────────────

  group('client failure', () {
    test('returns a domain error when the search endpoint returns HTTP 404', () async {
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/search',
        response: http.Response('{}', 404),
      );

      final result = await buildHandler().call(_request({'query': 'missing'}));

      expect(result.isError, isTrue);
      expect(_errorPayload(result), contains('code'));
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
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/search',
        response: ok('{"packages":[$sixPackages]}'),
      );
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/',
        response: ok(readFixture('package_info.json')),
      );
      stubUrl(
        mock: mockHttp,
        urlFragment: '/score',
        response: ok(readFixture('package_score.json')),
      );

      final result = await buildHandler().call(_request({'query': 'pkg'}));

      expect(_summaries(result).length, lessThanOrEqualTo(5));
    });
  });
}
