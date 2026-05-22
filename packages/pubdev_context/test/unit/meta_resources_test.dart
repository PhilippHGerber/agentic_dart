/// Unit tests for [MetaResourcesHandler].
///
/// Covers both the `pub://meta/scoring` and `pub://meta/sdk-versions` handlers,
/// including cache behaviour and URI routing. All HTTP is mocked via mocktail;
/// no live network calls are made.
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:pubdev_context/src/cache/memory_cache.dart';
import 'package:pubdev_context/src/resources/meta_resources.dart';
import 'package:test/test.dart';

// ─── Mocks ────────────────────────────────────────────────────────────────────

class _MockHttpClient extends Mock implements http.Client {}

// ─── Fixtures ─────────────────────────────────────────────────────────────────

final String _kDartVersionJson = jsonEncode({
  'version': '3.5.0',
  'date': '2024-07-10',
  'revision': 'abc123def456',
});

final String _kFlutterReleasesJson = jsonEncode({
  'current_release': {'beta': 'oldhash', 'stable': 'def456hash'},
  'releases': [
    {'hash': 'oldhash', 'version': '3.23.0', 'channel': 'beta'},
    {'hash': 'def456hash', 'version': '3.24.0', 'channel': 'stable'},
  ],
});

// ─── Helpers ──────────────────────────────────────────────────────────────────

http.Response _ok(String body) => http.Response(body, 200);

/// Stubs both Google Storage endpoints on [mock].
void _stubSdkVersionsEndpoints(_MockHttpClient mock) {
  when(
    () => mock.get(any(that: predicate<Uri>((u) => u.toString().contains('dart-archive')))),
  ).thenAnswer((_) async => _ok(_kDartVersionJson));
  when(
    () => mock.get(any(that: predicate<Uri>((u) => u.toString().contains('flutter_infra')))),
  ).thenAnswer((_) async => _ok(_kFlutterReleasesJson));
}

ReadResourceRequest _request(String uri) => ReadResourceRequest(uri: uri);

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late _MockHttpClient mockHttp;
  late DateTime fakeNow;
  late ResponseCache<String> cache;
  final loggedMessages = <(LoggingLevel, Object)>[];

  const kTestManifest = '[{"uri":"pub://meta/scoring"}]';

  MetaResourcesHandler buildHandler() => MetaResourcesHandler(
    httpClient: mockHttp,
    cache: cache,
    log: (level, data) => loggedMessages.add((level, data)),
    resourcesManifest: kTestManifest,
  );

  setUp(() {
    mockHttp = _MockHttpClient();
    registerFallbackValue(Uri.parse('https://example.com'));
    fakeNow = DateTime(2025, 5, 10);
    cache = ResponseCache(clock: () => fakeNow);
    loggedMessages.clear();
  });

  // ─── Scoring resource ────────────────────────────────────────────────────────

  group('scoring resource', () {
    test('returns the static scoring content without calling the HTTP client', () async {
      final result = await buildHandler().handleScoring(_request('pub://meta/scoring'));

      final content = (result.contents.single as TextResourceContents).text;
      expect(content, contains('160'));
      verifyNever(() => mockHttp.get(any()));
    });

    test('uses text/plain MIME type', () async {
      final result = await buildHandler().handleScoring(_request('pub://meta/scoring'));

      final content = result.contents.single as TextResourceContents;
      expect(content.mimeType, equals('text/plain'));
    });

    test('response URI matches the request URI', () async {
      final result = await buildHandler().handleScoring(_request('pub://meta/scoring'));

      final content = result.contents.single as TextResourceContents;
      expect(content.uri, equals('pub://meta/scoring'));
    });

    test('returns kScoringContent verbatim', () async {
      final result = await buildHandler().handleScoring(_request('pub://meta/scoring'));

      final content = (result.contents.single as TextResourceContents).text;
      expect(content, equals(kScoringContent));
    });

    test('logs a debug cache-miss message on first access', () async {
      await buildHandler().handleScoring(_request('pub://meta/scoring'));

      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString())
          .toList();
      expect(debugLogs.any((m) => m.contains('cache miss')), isTrue);
    });

    test('returns the scoring content on second access served from cache', () async {
      final handler = buildHandler();

      await handler.handleScoring(_request('pub://meta/scoring'));
      fakeNow = fakeNow.add(const Duration(hours: 1));
      final result = await handler.handleScoring(_request('pub://meta/scoring'));

      final content = (result.contents.single as TextResourceContents).text;
      expect(content, equals(kScoringContent));
    });

    test('logs a debug cache-hit message on second access', () async {
      final handler = buildHandler();

      await handler.handleScoring(_request('pub://meta/scoring'));
      fakeNow = fakeNow.add(const Duration(hours: 1));
      await handler.handleScoring(_request('pub://meta/scoring'));

      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString())
          .toList();
      expect(debugLogs.any((m) => m.contains('cache hit')), isTrue);
    });

    test('does not call the HTTP client on second access', () async {
      final handler = buildHandler();

      await handler.handleScoring(_request('pub://meta/scoring'));
      fakeNow = fakeNow.add(const Duration(hours: 1));
      await handler.handleScoring(_request('pub://meta/scoring'));

      verifyNever(() => mockHttp.get(any()));
    });
  });

  // ─── SDK versions resource ───────────────────────────────────────────────────

  group('sdk-versions resource', () {
    test('fetches the Dart VERSION endpoint', () async {
      _stubSdkVersionsEndpoints(mockHttp);

      await buildHandler().handleSdkVersions(_request('pub://meta/sdk-versions'));

      verify(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('dart-archive'))),
        ),
      ).called(1);
    });

    test('fetches the Flutter releases endpoint', () async {
      _stubSdkVersionsEndpoints(mockHttp);

      await buildHandler().handleSdkVersions(_request('pub://meta/sdk-versions'));

      verify(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('flutter_infra'))),
        ),
      ).called(1);
    });

    test('returns a JSON object with a dart version field', () async {
      _stubSdkVersionsEndpoints(mockHttp);

      final result = await buildHandler().handleSdkVersions(_request('pub://meta/sdk-versions'));

      final content = result.contents.single as TextResourceContents;
      final json = jsonDecode(content.text) as Map<String, Object?>;
      expect(json['dart'], equals('3.5.0'));
    });

    test('returns a JSON object with a flutter version field', () async {
      _stubSdkVersionsEndpoints(mockHttp);

      final result = await buildHandler().handleSdkVersions(_request('pub://meta/sdk-versions'));

      final content = result.contents.single as TextResourceContents;
      final json = jsonDecode(content.text) as Map<String, Object?>;
      expect(json['flutter'], equals('3.24.0'));
    });

    test('uses application/json MIME type', () async {
      _stubSdkVersionsEndpoints(mockHttp);

      final result = await buildHandler().handleSdkVersions(_request('pub://meta/sdk-versions'));

      final content = result.contents.single as TextResourceContents;
      expect(content.mimeType, equals('application/json'));
    });

    test('response URI matches the request URI', () async {
      _stubSdkVersionsEndpoints(mockHttp);

      final result = await buildHandler().handleSdkVersions(_request('pub://meta/sdk-versions'));

      final content = result.contents.single as TextResourceContents;
      expect(content.uri, equals('pub://meta/sdk-versions'));
    });

    test('logs a debug cache-miss message on first access', () async {
      _stubSdkVersionsEndpoints(mockHttp);

      await buildHandler().handleSdkVersions(_request('pub://meta/sdk-versions'));

      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString())
          .toList();
      expect(debugLogs.any((m) => m.contains('cache miss')), isTrue);
    });

    test('logs an info message when issuing the HTTP fetch', () async {
      _stubSdkVersionsEndpoints(mockHttp);

      await buildHandler().handleSdkVersions(_request('pub://meta/sdk-versions'));

      final infoLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.info)
          .map((m) => m.$2.toString())
          .toList();
      expect(infoLogs.any((m) => m.contains('HTTP fetch')), isTrue);
    });

    test('returns a cached result on second access without making HTTP calls', () async {
      _stubSdkVersionsEndpoints(mockHttp);
      final handler = buildHandler();

      await handler.handleSdkVersions(_request('pub://meta/sdk-versions'));
      fakeNow = fakeNow.add(const Duration(hours: 1));
      await handler.handleSdkVersions(_request('pub://meta/sdk-versions'));

      verify(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('dart-archive'))),
        ),
      ).called(1);
    });

    test('logs a debug cache-hit message on second access', () async {
      _stubSdkVersionsEndpoints(mockHttp);
      final handler = buildHandler();

      await handler.handleSdkVersions(_request('pub://meta/sdk-versions'));
      fakeNow = fakeNow.add(const Duration(hours: 1));
      await handler.handleSdkVersions(_request('pub://meta/sdk-versions'));

      final debugLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.debug)
          .map((m) => m.$2.toString())
          .toList();
      expect(debugLogs.any((m) => m.contains('cache hit')), isTrue);
    });

    test('re-fetches both endpoints after the 24-hour TTL expires', () async {
      _stubSdkVersionsEndpoints(mockHttp);
      final handler = buildHandler();

      await handler.handleSdkVersions(_request('pub://meta/sdk-versions'));
      fakeNow = fakeNow.add(const Duration(hours: 25));
      await handler.handleSdkVersions(_request('pub://meta/sdk-versions'));

      verify(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('dart-archive'))),
        ),
      ).called(2);
    });

    test('throws when the Dart endpoint returns a non-200 status', () async {
      when(
        () => mockHttp.get(any(that: predicate<Uri>((u) => u.toString().contains('dart-archive')))),
      ).thenAnswer((_) async => http.Response('Not Found', 404));
      when(
        () =>
            mockHttp.get(any(that: predicate<Uri>((u) => u.toString().contains('flutter_infra')))),
      ).thenAnswer((_) async => _ok(_kFlutterReleasesJson));

      await expectLater(
        buildHandler().handleSdkVersions(_request('pub://meta/sdk-versions')),
        throwsA(isA<Exception>()),
      );
    });

    test('throws when the Flutter endpoint returns a non-200 status', () async {
      when(
        () => mockHttp.get(any(that: predicate<Uri>((u) => u.toString().contains('dart-archive')))),
      ).thenAnswer((_) async => _ok(_kDartVersionJson));
      when(
        () =>
            mockHttp.get(any(that: predicate<Uri>((u) => u.toString().contains('flutter_infra')))),
      ).thenAnswer((_) async => http.Response('Server Error', 500));

      await expectLater(
        buildHandler().handleSdkVersions(_request('pub://meta/sdk-versions')),
        throwsA(isA<Exception>()),
      );
    });

    test('throws when the stable Flutter release hash is not found in releases', () async {
      final brokenReleasesJson = jsonEncode({
        'current_release': {'stable': 'missing_hash'},
        'releases': [
          {'hash': 'other_hash', 'version': '3.24.0', 'channel': 'stable'},
        ],
      });
      when(
        () => mockHttp.get(any(that: predicate<Uri>((u) => u.toString().contains('dart-archive')))),
      ).thenAnswer((_) async => _ok(_kDartVersionJson));
      when(
        () =>
            mockHttp.get(any(that: predicate<Uri>((u) => u.toString().contains('flutter_infra')))),
      ).thenAnswer((_) async => _ok(brokenReleasesJson));

      await expectLater(
        buildHandler().handleSdkVersions(_request('pub://meta/sdk-versions')),
        throwsA(isA<Exception>()),
      );
    });
  });

  // ─── Resources manifest ──────────────────────────────────────────────────────

  group('resources manifest', () {
    test('returns the manifest JSON passed at construction time', () async {
      final result = await buildHandler().handleResources(_request('pub://meta/resources'));

      final content = (result.contents.single as TextResourceContents).text;
      expect(content, equals(kTestManifest));
    });

    test('uses application/json MIME type', () async {
      final result = await buildHandler().handleResources(_request('pub://meta/resources'));

      final content = result.contents.single as TextResourceContents;
      expect(content.mimeType, equals('application/json'));
    });

    test('response URI matches the request URI', () async {
      final result = await buildHandler().handleResources(_request('pub://meta/resources'));

      final content = result.contents.single as TextResourceContents;
      expect(content.uri, equals('pub://meta/resources'));
    });

    test('does not call the HTTP client', () async {
      await buildHandler().handleResources(_request('pub://meta/resources'));

      verifyNever(() => mockHttp.get(any()));
    });
  });

  // ─── URI routing ─────────────────────────────────────────────────────────────

  group('URI routing', () {
    test('scoring handler does not reach the Dart VERSION endpoint', () async {
      await buildHandler().handleScoring(_request('pub://meta/scoring'));

      verifyNever(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('dart-archive'))),
        ),
      );
    });

    test('scoring handler does not reach the Flutter releases endpoint', () async {
      await buildHandler().handleScoring(_request('pub://meta/scoring'));

      verifyNever(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('flutter_infra'))),
        ),
      );
    });
  });
}
