/// Unit tests for [GetChangelogHandler].
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:pubdev_context/src/cache/memory_cache.dart';
import 'package:pubdev_context/src/data/models.dart';
import 'package:pubdev_context/src/data/pub_client.dart';
import 'package:pubdev_context/src/tools/get_changelog.dart';
import 'package:test/test.dart';

// ─── Mocks ────────────────────────────────────────────────────────────────────

class _MockHttpClient extends Mock implements http.Client {}

// ─── Helpers ──────────────────────────────────────────────────────────────────

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

/// Stubs a successful changelog fetch for package [name].
void _stubSuccess(_MockHttpClient mock, {String name = 'http', String? html}) {
  _stubUrl(
    mock: mock,
    urlFragment: '/packages/$name/changelog',
    response: _ok(html ?? _defaultChangelogHtml),
  );
}

/// HTML with three versions: 2.0.0 (breaking), 1.5.0, 1.0.0.
const _defaultChangelogHtml = '''
<h2>2.0.0</h2>
<p>Breaking change: removed the old API.</p>
<h2>1.5.0</h2>
<p>Added new feature.</p>
<h2>1.0.0</h2>
<p>Initial release.</p>
''';

/// HTML using bracketed version format.
const _bracketedChangelogHtml = '''
<h2>[2.0.0]</h2>
<p>Breaking change: removed the old API.</p>
<h2>[1.0.0]</h2>
<p>Initial release.</p>
''';

/// HTML with no version headings.
const _noHeadingsHtml = '<p>This package has no formal changelog yet.</p>';

/// Creates a [CallToolRequest] for `get_changelog` with the given [args].
CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'get_changelog', arguments: args);

/// Decodes the first content item of [result] as a JSON list.
List<Map<String, Object?>> _entries(CallToolResult result) =>
    (jsonDecode((result.content.first as TextContent).text) as List<Object?>)
        .cast<Map<String, Object?>>();

/// Decodes the first content item of [result] as a JSON error payload.
Map<String, Object?> _errorPayload(CallToolResult result) =>
    jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late _MockHttpClient mockHttp;
  late PubDevClient client;
  late DateTime fakeNow;
  late ResponseCache<List<ChangelogEntry>> cache;
  final loggedMessages = <(LoggingLevel, Object)>[];

  GetChangelogHandler buildHandler() => GetChangelogHandler(
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

  // ─── Successful parse ─────────────────────────────────────────────────────────

  group('successful parse', () {
    test('returns a JSON list without isError set', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(result.isError, isNull);
    });

    test('returns three entries for the default changelog', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_entries(result), hasLength(3));
    });

    test('first entry version is 2.0.0', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_entries(result).first['version'], equals('2.0.0'));
    });

    test('entries are ordered newest-first', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));
      final versions = _entries(result).map((e) => e['version']).toList();

      expect(versions, equals(['2.0.0', '1.5.0', '1.0.0']));
    });

    test('breaking flag is true for an entry containing "breaking"', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_entries(result).first['breaking'], isTrue);
    });

    test('breaking flag is false for an entry without "breaking"', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_entries(result)[1]['breaking'], isFalse);
    });

    test('breaking detection is case-insensitive', () async {
      const html = '<h2>1.0.0</h2><p>BREAKING CHANGE: new API.</p>';
      _stubSuccess(mockHttp, html: html);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_entries(result).first['breaking'], isTrue);
    });

    test('parses ## 1.2.3 heading format', () async {
      const html = '<h2>3.0.0</h2><p>Changes.</p>';
      _stubSuccess(mockHttp, html: html);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_entries(result).first['version'], equals('3.0.0'));
    });

    test('parses ## [1.2.3] bracketed heading format', () async {
      _stubSuccess(mockHttp, html: _bracketedChangelogHtml);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_entries(result).first['version'], equals('2.0.0'));
    });

    test('bracketed format strips the brackets from the version string', () async {
      _stubSuccess(mockHttp, html: _bracketedChangelogHtml);

      final result = await buildHandler().call(_request({'name': 'http'}));
      final versions = _entries(result).map((e) => e['version']).toList();

      expect(versions, equals(['2.0.0', '1.0.0']));
    });

    test('both ## and ## [] formats coexist in one changelog', () async {
      const html = '''
<h2>[2.0.0]</h2><p>Breaking change.</p>
<h2>1.0.0</h2><p>Initial release.</p>
''';
      _stubSuccess(mockHttp, html: html);

      final result = await buildHandler().call(_request({'name': 'http'}));
      final versions = _entries(result).map((e) => e['version']).toList();

      expect(versions, equals(['2.0.0', '1.0.0']));
    });

    test('each entry includes a changes field', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_entries(result).every((e) => e.containsKey('changes')), isTrue);
    });

    test('each entry includes a breaking field', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_entries(result).every((e) => e.containsKey('breaking')), isTrue);
    });
  });

  // ─── version_limit ────────────────────────────────────────────────────────────

  group('version_limit', () {
    test('defaults to 5 entries when version_limit is absent', () async {
      const html = '''
<h2>5.0.0</h2><p>v5.</p>
<h2>4.0.0</h2><p>v4.</p>
<h2>3.0.0</h2><p>v3.</p>
<h2>2.0.0</h2><p>v2.</p>
<h2>1.0.0</h2><p>v1.</p>
<h2>0.9.0</h2><p>v0.9.</p>
''';
      _stubSuccess(mockHttp, html: html);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_entries(result), hasLength(5));
    });

    test('caps entries at a custom version_limit', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(
        _request({'name': 'http', 'version_limit': 2}),
      );

      expect(_entries(result), hasLength(2));
    });

    test('returns all entries when version_limit exceeds the changelog size', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(
        _request({'name': 'http', 'version_limit': 100}),
      );

      expect(_entries(result), hasLength(3));
    });
  });

  // ─── no_documentation ────────────────────────────────────────────────────────

  group('no_documentation', () {
    test('returns isError true when changelog has no version headings', () async {
      _stubSuccess(mockHttp, html: _noHeadingsHtml);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(result.isError, isTrue);
    });

    test('error code is no_documentation when no headings found', () async {
      _stubSuccess(mockHttp, html: _noHeadingsHtml);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_errorPayload(result)['error'], equals('no_documentation'));
    });

    test('error payload contains a suggestion', () async {
      _stubSuccess(mockHttp, html: _noHeadingsHtml);

      final result = await buildHandler().call(_request({'name': 'http'}));

      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  // ─── from_version found ───────────────────────────────────────────────────────

  group('from_version found in changelog', () {
    test('excludes the boundary version and returns newer entries', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(
        _request({'name': 'http', 'from_version': '1.5.0'}),
      );

      expect(
        _entries(result).map((e) => e['version']).toList(),
        equals(['2.0.0']),
      );
    });

    test('excludes the boundary version and all older entries', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(
        _request({'name': 'http', 'from_version': '1.0.0'}),
      );

      expect(
        _entries(result).map((e) => e['version']).toList(),
        equals(['2.0.0', '1.5.0']),
      );
    });

    test('returns empty list when from_version is the newest entry', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(
        _request({'name': 'http', 'from_version': '2.0.0'}),
      );

      expect(result.isError, isNull);
      expect(_entries(result), isEmpty);
    });

    test('version_limit is applied after from_version boundary', () async {
      const html = '''
<h2>4.0.0</h2><p>v4.</p>
<h2>3.0.0</h2><p>v3.</p>
<h2>2.0.0</h2><p>v2.</p>
<h2>1.0.0</h2><p>v1.</p>
''';
      _stubSuccess(mockHttp, html: html);

      final result = await buildHandler().call(
        _request({'name': 'http', 'from_version': '1.0.0', 'version_limit': 2}),
      );

      expect(
        _entries(result).map((e) => e['version']).toList(),
        equals(['4.0.0', '3.0.0']),
      );
    });
  });

  // ─── from_version not found ───────────────────────────────────────────────────

  group('from_version not found in changelog', () {
    test('uses next-older heading as boundary', () async {
      _stubSuccess(mockHttp);

      // 1.7.0 not in list; next-older is 1.5.0 → exclude 1.5.0 and 1.0.0
      final result = await buildHandler().call(
        _request({'name': 'http', 'from_version': '1.7.0'}),
      );

      expect(
        _entries(result).map((e) => e['version']).toList(),
        equals(['2.0.0']),
      );
    });

    test('returns invalid_input when no older heading exists', () async {
      _stubSuccess(mockHttp);

      // 0.1.0 is older than all entries
      final result = await buildHandler().call(
        _request({'name': 'http', 'from_version': '0.1.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['error'], equals('invalid_input'));
    });

    test('invalid_input error contains a suggestion', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(
        _request({'name': 'http', 'from_version': '0.1.0'}),
      );

      expect(_errorPayload(result), contains('suggestion'));
    });
  });

  // ─── Cache hit ────────────────────────────────────────────────────────────────

  group('cache hit', () {
    test('does not issue a second HTTP request within the TTL window', () async {
      _stubSuccess(mockHttp);
      final handler = buildHandler();

      await handler.call(_request({'name': 'http'}));
      fakeNow = fakeNow.add(const Duration(minutes: 14));
      await handler.call(_request({'name': 'http'}));

      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/packages/http/changelog'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
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

    test('cache hit applies from_version filter to cached entries', () async {
      _stubSuccess(mockHttp);
      final handler = buildHandler();

      await handler.call(_request({'name': 'http'}));
      fakeNow = fakeNow.add(const Duration(minutes: 14));
      final result = await handler.call(
        _request({'name': 'http', 'from_version': '1.5.0'}),
      );

      expect(result.isError, isNull);
      expect(
        _entries(result).map((e) => e['version']).toList(),
        equals(['2.0.0']),
      );
    });

    test('no_documentation result is cached so second call avoids HTTP', () async {
      _stubSuccess(mockHttp, html: _noHeadingsHtml);
      final handler = buildHandler();

      await handler.call(_request({'name': 'http'}));
      fakeNow = fakeNow.add(const Duration(minutes: 14));
      await handler.call(_request({'name': 'http'}));

      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/packages/http/changelog'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });
  });

  // ─── Cache miss ───────────────────────────────────────────────────────────────

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

  // ─── Package not found ────────────────────────────────────────────────────────

  group('package not found', () {
    test('returns isError true when the changelog page returns 404', () async {
      _stubUrl(
        mock: mockHttp,
        urlFragment: '/packages/unknown/changelog',
        response: _notFound(),
      );

      final result = await buildHandler().call(_request({'name': 'unknown'}));

      expect(result.isError, isTrue);
    });

    test('error code is package_not_found on 404', () async {
      _stubUrl(
        mock: mockHttp,
        urlFragment: '/packages/unknown/changelog',
        response: _notFound(),
      );

      final result = await buildHandler().call(_request({'name': 'unknown'}));

      expect(_errorPayload(result)['error'], equals('package_not_found'));
    });

    test('HTTP error result is not cached so the next call retries', () async {
      _stubUrl(
        mock: mockHttp,
        urlFragment: '/packages/unknown/changelog',
        response: _notFound(),
      );
      final handler = buildHandler();

      await handler.call(_request({'name': 'unknown'}));
      await handler.call(_request({'name': 'unknown'}));

      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/packages/unknown/changelog'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(greaterThan(1));
    });
  });
}
