/// Unit tests for [GetPackageHandler].
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:pubdev_context/src/cache/memory_cache.dart';
import 'package:pubdev_context/src/data/models.dart';
import 'package:pubdev_context/src/data/pub_client.dart';
import 'package:pubdev_context/src/tools/get_package.dart';
import 'package:test/test.dart';

// ─── Mocks ────────────────────────────────────────────────────────────────────

class _MockHttpClient extends Mock implements http.Client {}

// ─── Helpers ──────────────────────────────────────────────────────────────────

String _readFixture(String name) => File('test/fixtures/$name').readAsStringSync();

http.Response _ok(String body) => http.Response(body, 200);
http.Response _notFound() => http.Response('Not Found', 404);

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

/// Stubs the three endpoints for a successful `get_package` call (latest version).
///
/// Registration order matters: mocktail resolves stubs LIFO, so the more specific
/// `/score` stub must be registered last to win over the `/api/packages/http` stub.
void _stubSuccess(_MockHttpClient mock) {
  _stubUrl(
    mock: mock,
    urlFragment: '/documentation/http/latest/',
    response: _notFound(),
  );
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

/// Stubs the two endpoints for a version-pinned `get_package` call.
void _stubVersionSuccess(_MockHttpClient mock, String version) {
  final versionData = jsonDecode(_readFixture('package_info.json')) as Map<String, Object?>;
  final latestData = versionData['latest']! as Map<String, Object?>;

  _stubUrl(
    mock: mock,
    urlFragment: '/api/packages/http/versions/$version',
    response: _ok(jsonEncode(latestData)),
  );
  _stubUrl(
    mock: mock,
    urlFragment: '/api/packages/http/score',
    response: _ok(_readFixture('package_score.json')),
  );
}

/// Creates a [CallToolRequest] for `get_package` with the given [args].
CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'get_package', arguments: args);

/// Decodes the first content item of [result] as a JSON map.
Map<String, Object?> _detail(CallToolResult result) =>
    jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;

/// Decodes the first content item of [result] as a JSON error payload.
Map<String, Object?> _errorPayload(CallToolResult result) =>
    jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late _MockHttpClient mockHttp;
  late PubDevClient client;
  late DateTime fakeNow;
  late ResponseCache<PackageDetail> cache;
  final loggedMessages = <(LoggingLevel, Object)>[];

  GetPackageHandler buildHandler() => GetPackageHandler(
    client: client,
    cache: cache,
    log: (level, data) => loggedMessages.add((level, data)),
  );

  setUp(() {
    mockHttp = _MockHttpClient();
    registerFallbackValue(Uri.parse('https://pub.dev'));
    client = PubDevClient(httpClient: mockHttp, retryPolicy: _instant);
    fakeNow = DateTime(2026, 5, 12);
    cache = ResponseCache(clock: () => fakeNow);
    loggedMessages.clear();
  });

  tearDown(() => client.close());

  // ─── Successful fetch (latest) ────────────────────────────────────────────────

  group('successful fetch for latest version', () {
    test('returns a JSON object without isError set', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(result.isError, isNull);
    });

    test('result contains the package name', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_detail(result)['name'], equals('http'));
    });

    test('result contains the version field', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_detail(result)['version'], equals('1.6.0'));
    });

    test('result contains the description field', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_detail(result)['description'], isNotEmpty);
    });

    test('result contains activeMaintenance field', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_detail(result), contains('activeMaintenance'));
    });

    test('result contains likes from score', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_detail(result)['likes'], equals(8435));
    });

    test('result contains pubPoints from score', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_detail(result)['pubPoints'], equals(160));
    });

    test('result contains sdkConstraints with dart field', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));
      final constraints = _detail(result)['sdkConstraints']! as Map<String, Object?>;

      expect(constraints, contains('dart'));
    });

    test('result contains platforms list', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_detail(result)['platforms'], isA<List<Object?>>());
    });

    test('result contains dependencies map', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_detail(result)['dependencies'], isA<Map<String, Object?>>());
    });

    test('result contains devDependencies map', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_detail(result)['devDependencies'], isA<Map<String, Object?>>());
    });

    test('result contains versionsRecent as a list', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_detail(result)['versionsRecent'], isA<List<Object?>>());
    });

    test('versionsRecent contains at most five entries', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));
      final versions = _detail(result)['versionsRecent']! as List<Object?>;

      expect(versions.length, lessThanOrEqualTo(5));
    });

    test('versionsRecent is ordered newest-first', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));
      final versions = (_detail(result)['versionsRecent']! as List<Object?>).cast<String>();

      expect(versions.first, equals('1.6.0'));
    });

    test('result contains publisher from score tags', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_detail(result)['publisher'], equals('dart.dev'));
    });

    test('result contains license from score tags', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_detail(result)['license'], isNotNull);
    });

    test('result contains isFlutterFavorite field', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_detail(result), contains('isFlutterFavorite'));
    });

    test('result contains repository from pubspec', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_detail(result)['repository'], isNotNull);
    });
  });

  // ─── readmeExcerpt ────────────────────────────────────────────────────────────

  group('readmeExcerpt', () {
    test('is absent when the docs page returns 404', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_detail(result).containsKey('readmeExcerpt'), isFalse);
    });

    test('is present and non-empty when the docs page returns valid HTML', () async {
      const html = '<div class="desc markdown"><p>A great HTTP library.</p></div>';
      _stubUrl(
        mock: mockHttp,
        urlFragment: '/documentation/http/latest/',
        response: _ok(html),
      );
      _stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http',
        response: _ok(_readFixture('package_info.json')),
      );
      _stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http/score',
        response: _ok(_readFixture('package_score.json')),
      );

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_detail(result)['readmeExcerpt'], isNotEmpty);
    });
  });

  // ─── Version-pinned fetch ─────────────────────────────────────────────────────

  group('version-pinned fetch', () {
    test('fetches from the versions endpoint when version is supplied', () async {
      _stubVersionSuccess(mockHttp, '1.5.0');

      await buildHandler().call(_request({'name': 'http', 'version': '1.5.0'}));

      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/api/packages/http/versions/1.5.0'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('does not call the unversioned package endpoint when version is supplied', () async {
      _stubVersionSuccess(mockHttp, '1.5.0');

      await buildHandler().call(_request({'name': 'http', 'version': '1.5.0'}));

      verifyNever(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) =>
                  u.toString().contains('/api/packages/http') &&
                  !u.toString().contains('/score') &&
                  !u.toString().contains('/versions/'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      );
    });

    test('returns a valid result for a version-pinned request', () async {
      _stubVersionSuccess(mockHttp, '1.5.0');

      final result = await buildHandler().call(_request({'name': 'http', 'version': '1.5.0'}));

      expect(result.isError, isNull);
      expect(_detail(result)['name'], equals('http'));
    });
  });

  // ─── Cache hit ──────────────────────────────────────────────────────────────

  group('cache hit', () {
    test('does not issue a second HTTP request within the TTL window', () async {
      _stubSuccess(mockHttp);
      final handler = buildHandler();

      await handler.call(_request({'name': 'http'}));
      fakeNow = fakeNow.add(const Duration(minutes: 14));
      await handler.call(_request({'name': 'http'}));

      verify(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('/api/packages/http'))),
          headers: any(named: 'headers'),
        ),
      ).called(lessThan(4));
    });

    test('logs a debug cache-hit message on the second call', () async {
      _stubSuccess(mockHttp);
      final handler = buildHandler();

      await handler.call(_request({'name': 'http'}));
      loggedMessages.clear();
      fakeNow = fakeNow.add(const Duration(minutes: 14));
      await handler.call(_request({'name': 'http'}));

      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString());
      expect(debugLogs.any((m) => m.contains('cache hit')), isTrue);
    });

    test('uses a separate cache key for version-pinned requests', () async {
      _stubSuccess(mockHttp);
      _stubVersionSuccess(mockHttp, '1.5.0');
      final handler = buildHandler();

      await handler.call(_request({'name': 'http'}));
      await handler.call(_request({'name': 'http', 'version': '1.5.0'}));

      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/api/packages/http/versions/1.5.0'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });
  });

  // ─── Cache miss ─────────────────────────────────────────────────────────────

  group('cache miss', () {
    test('logs a debug cache-miss message on first call', () async {
      _stubSuccess(mockHttp);

      await buildHandler().call(_request({'name': 'http'}));

      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString());
      expect(debugLogs.any((m) => m.contains('cache miss')), isTrue);
    });

    test('logs an info HTTP-request message containing the package name', () async {
      _stubSuccess(mockHttp);

      await buildHandler().call(_request({'name': 'http'}));

      final infoLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.info)
          .map((m) => m.$2.toString());
      expect(infoLogs.any((m) => m.contains('name=http')), isTrue);
    });
  });

  // ─── 404 / package not found ─────────────────────────────────────────────────

  group('package not found', () {
    test('returns a domain error when the package endpoint returns 404', () async {
      _stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/unknown',
        response: _notFound(),
      );

      final result = await buildHandler().call(_request({'name': 'unknown'}));

      expect(result.isError, isTrue);
    });

    test('domain error code is package_not_found on 404', () async {
      _stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/unknown',
        response: _notFound(),
      );

      final result = await buildHandler().call(_request({'name': 'unknown'}));

      expect(_errorPayload(result)['error'], equals('package_not_found'));
    });

    test('domain error contains a suggestion on 404', () async {
      _stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/unknown',
        response: _notFound(),
      );

      final result = await buildHandler().call(_request({'name': 'unknown'}));

      expect(_errorPayload(result), contains('suggestion'));
    });

    test('error result is not cached so the next call retries the HTTP request', () async {
      _stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/unknown',
        response: _notFound(),
      );
      final handler = buildHandler();

      await handler.call(_request({'name': 'unknown'}));
      await handler.call(_request({'name': 'unknown'}));

      verify(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('/api/packages/unknown'))),
          headers: any(named: 'headers'),
        ),
      ).called(greaterThan(1));
    });

    test('returns a domain error when the version endpoint returns 404', () async {
      _stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http/versions/9.9.9',
        response: _notFound(),
      );
      _stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http/score',
        response: _ok(_readFixture('package_score.json')),
      );

      final result = await buildHandler().call(
        _request({'name': 'http', 'version': '9.9.9'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['error'], equals('package_not_found'));
    });
  });
}
