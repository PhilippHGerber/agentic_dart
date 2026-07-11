/// Unit tests for [ComparePackagesHandler].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:pubdev_context/src/cache/cache_registry.dart';
import 'package:pubdev_context/src/cache/keyed_cache.dart';
import 'package:pubdev_context/src/data/domain_error.dart';
import 'package:pubdev_context/src/data/models.dart';
import 'package:pubdev_context/src/data/pub_client.dart';
import 'package:pubdev_context/src/tools/compare_packages.dart';
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

/// Returns a minimal package-info JSON body for [name].
String _packageInfoJson(String name) => jsonEncode({
  'name': name,
  'latest': {
    'version': '2.0.0',
    'published': '2024-06-01T00:00:00.000Z',
    'pubspec': {
      'name': name,
      'version': '2.0.0',
      'description': 'A package called $name.',
      'environment': {'sdk': '^3.3.0', 'flutter': '>=3.0.0'},
      'dependencies': {'http': '^1.0.0', 'meta': '^1.0.0'},
    },
  },
  'versions': [
    {'version': '2.0.0'},
    {'version': '1.0.0'},
  ],
});

/// Returns a minimal score JSON body.
String _packageScoreJson() => jsonEncode({
  'grantedPoints': 120,
  'maxPoints': 160,
  'likeCount': 500,
  'downloadCount30Days': 20000,
  'tags': [
    'sdk:dart',
    'sdk:flutter',
    'platform:android',
    'platform:ios',
    'license:mit',
  ],
});

/// Stubs all three endpoints for a successful `getPackage` call for [name].
///
/// The `/score` stub is registered last so mocktail resolves it before the
/// broader `/api/packages/{name}` stub.
void _stubSuccess(_MockHttpClient mock, String name) {
  _stubUrl(mock: mock, urlFragment: '/documentation/$name/latest/', response: _notFound());
  _stubUrl(
    mock: mock,
    urlFragment: '/api/packages/$name',
    response: _ok(_packageInfoJson(name)),
  );
  _stubUrl(
    mock: mock,
    urlFragment: '/api/packages/$name/score',
    response: _ok(_packageScoreJson()),
  );
}

/// Stubs a successful `getPackage` for [name], but gates the package-info
/// endpoint on a [Completer] so the fetch cannot complete until the returned
/// completer is completed. The `score` and documentation endpoints resolve
/// immediately. Used to force out-of-order completion between packages.
Completer<void> _stubGatedInfo(_MockHttpClient mock, String name) {
  final gate = Completer<void>();
  _stubUrl(mock: mock, urlFragment: '/documentation/$name/latest/', response: _notFound());
  when(
    () => mock.get(
      any(that: predicate<Uri>((u) => u.toString().endsWith('/api/packages/$name'))),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer((_) async {
    await gate.future;
    return _ok(_packageInfoJson(name));
  });
  _stubUrl(
    mock: mock,
    urlFragment: '/api/packages/$name/score',
    response: _ok(_packageScoreJson()),
  );
  return gate;
}

/// Stubs the package endpoint for [name] to return 404.
void _stubNotFound(_MockHttpClient mock, String name) {
  _stubUrl(mock: mock, urlFragment: '/api/packages/$name', response: _notFound());
}

/// Creates a [CallToolRequest] for `compare_packages` with [names].
CallToolRequest _request(List<String> names) =>
    CallToolRequest(name: 'compare_packages', arguments: {'names': names});

/// Decodes the first content item of [result] as a JSON map.
Map<String, Object?> _payload(CallToolResult result) =>
    jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;

/// Extracts the inner `error` object from a failed result's nested error schema.
Map<String, Object?> _errorInner(CallToolResult result) {
  final inner = _payload(result)['error'];
  if (inner is! Map<String, Object?>) throw StateError('No nested error object');
  return inner;
}

/// Extracts the `matrix` sub-map from a successful result payload.
Map<String, Object?> _matrixOf(CallToolResult result) =>
    _payload(result)['matrix']! as Map<String, Object?>;

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late _MockHttpClient mockHttp;
  late PubDevClient client;
  late KeyedCache<PackageDetailId, PackageDetail> packageDetail;
  final loggedMessages = <(LoggingLevel, Object)>[];

  ComparePackagesHandler buildHandler({
    void Function(LoggingLevel, Object)? log,
  }) => ComparePackagesHandler(
    client: client,
    packageDetail: packageDetail,
    log: log ?? (level, data) => loggedMessages.add((level, data)),
  );

  setUp(() {
    mockHttp = _MockHttpClient();
    registerFallbackValue(Uri.parse('https://pub.dev'));
    client = PubDevClient(httpClient: mockHttp, retryPolicy: _instant);
    packageDetail = CacheRegistry(client: client).packageDetail;
    loggedMessages.clear();
  });

  tearDown(() => client.close());

  // ─── Input validation ─────────────────────────────────────────────────────────

  group('input validation', () {
    test('names with one entry sets isError to true', () async {
      final result = await buildHandler().call(_request(['http']));

      expect(result.isError, isTrue);
    });

    test('names with one entry returns an invalid_input domain error', () async {
      final result = await buildHandler().call(_request(['http']));

      expect(_errorInner(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('names with six entries sets isError to true', () async {
      final result = await buildHandler().call(_request(['a', 'b', 'c', 'd', 'e', 'f']));

      expect(result.isError, isTrue);
    });

    test('names with six entries returns an invalid_input domain error', () async {
      final result = await buildHandler().call(_request(['a', 'b', 'c', 'd', 'e', 'f']));

      expect(_errorInner(result)['code'], equals(DomainErrors.invalidArgument));
    });

    test('invalid_input error includes a suggestion', () async {
      final result = await buildHandler().call(_request(['http']));

      expect(_errorInner(result), contains('suggestion'));
    });
  });

  // ─── Successful comparison ────────────────────────────────────────────────────

  group('successful comparison', () {
    setUp(() {
      _stubSuccess(mockHttp, 'http');
      _stubSuccess(mockHttp, 'dio');
    });

    test('result is not an error when both packages succeed', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));

      expect(result.isError, isNull);
    });

    test('packages list matches the input names in order', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));

      expect(_payload(result)['packages'], equals(['http', 'dio']));
    });

    test('errors map is an empty object when all packages succeed', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));

      expect(_payload(result)['errors'], equals({}));
    });

    test('matrix contains the name field', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));

      expect(_matrixOf(result), contains('name'));
    });

    test('matrix name field maps each package to its name', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));
      final names = _matrixOf(result)['name']! as Map<String, Object?>;

      expect(names['http'], equals('http'));
      expect(names['dio'], equals('dio'));
    });

    test('matrix contains the version field', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));

      expect(_matrixOf(result), contains('version'));
    });

    test('matrix contains the description field', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));

      expect(_matrixOf(result), contains('description'));
    });

    test('matrix contains the likes field', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));

      expect(_matrixOf(result), contains('likes'));
    });

    test('matrix likes values are integers', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));
      final likes = _matrixOf(result)['likes']! as Map<String, Object?>;

      expect(likes['http'], isA<int>());
    });

    test('matrix contains the pubPoints field', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));

      expect(_matrixOf(result), contains('pubPoints'));
    });

    test('matrix contains the popularity field', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));

      expect(_matrixOf(result), contains('popularity'));
    });

    test('matrix contains the verified field', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));

      expect(_matrixOf(result), contains('verified'));
    });

    test('matrix contains the platforms field', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));

      expect(_matrixOf(result), contains('platforms'));
    });

    test('matrix contains the topics field', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));

      expect(_matrixOf(result), contains('topics'));
    });

    test('matrix contains the isFlutterFavorite field', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));

      expect(_matrixOf(result), contains('isFlutterFavorite'));
    });

    test('matrix contains the activeMaintenance field', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));

      expect(_matrixOf(result), contains('activeMaintenance'));
    });

    test('matrix contains the daysSinceUpdate field', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));

      expect(_matrixOf(result), contains('daysSinceUpdate'));
    });

    test('matrix daysSinceUpdate values are non-negative integers', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));
      final days = _matrixOf(result)['daysSinceUpdate']! as Map<String, Object?>;

      expect(days['http'], isA<int>());
      expect(days['http']! as int, greaterThanOrEqualTo(0));
    });

    test('matrix contains the license field', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));

      expect(_matrixOf(result), contains('license'));
    });

    test('matrix contains the sdkConstraints.dart field', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));

      expect(_matrixOf(result), contains('sdkConstraints.dart'));
    });

    test('matrix sdkConstraints.dart values are non-empty strings', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));
      final constraints = _matrixOf(result)['sdkConstraints.dart']! as Map<String, Object?>;

      expect(constraints['http'], isA<String>());
      expect(constraints['http']! as String, isNotEmpty);
    });

    test('matrix contains the sdkConstraints.flutter field when packages declare it', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));

      expect(_matrixOf(result), contains('sdkConstraints.flutter'));
    });

    test('matrix contains the dependencies field', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));

      expect(_matrixOf(result), contains('dependencies'));
    });

    test('matrix dependencies values reflect the number of runtime dependencies', () async {
      final result = await buildHandler().call(_request(['http', 'dio']));
      final deps = _matrixOf(result)['dependencies']! as Map<String, Object?>;

      expect(deps['http'], equals(2));
    });
  });

  // ─── Partial failure ──────────────────────────────────────────────────────────

  group('partial failure', () {
    setUp(() {
      _stubSuccess(mockHttp, 'http');
      _stubNotFound(mockHttp, 'unknown');
    });

    test('result is not an error when at least one package succeeds', () async {
      final result = await buildHandler().call(_request(['http', 'unknown']));

      expect(result.isError, isNull);
    });

    test('failed package appears in the errors map', () async {
      final result = await buildHandler().call(_request(['http', 'unknown']));
      final errors = _payload(result)['errors']! as Map<String, Object?>;

      expect(errors, contains('unknown'));
    });

    test('errors map contains the domain error code for the failed package', () async {
      final result = await buildHandler().call(_request(['http', 'unknown']));
      final errors = _payload(result)['errors']! as Map<String, Object?>;

      expect(errors['unknown'], equals(DomainErrors.packageNotFound));
    });

    test('successful package is present in the matrix', () async {
      final result = await buildHandler().call(_request(['http', 'unknown']));
      final names = _matrixOf(result)['name']! as Map<String, Object?>;

      expect(names, contains('http'));
    });

    test('failed package is absent from the matrix', () async {
      final result = await buildHandler().call(_request(['http', 'unknown']));
      final names = _matrixOf(result)['name']! as Map<String, Object?>;

      expect(names, isNot(contains('unknown')));
    });
  });

  // ─── All packages fail ────────────────────────────────────────────────────────

  group('all packages fail', () {
    setUp(() {
      _stubNotFound(mockHttp, 'unknown1');
      _stubNotFound(mockHttp, 'unknown2');
    });

    test('result sets isError to true when all packages fail', () async {
      final result = await buildHandler().call(_request(['unknown1', 'unknown2']));

      expect(result.isError, isTrue);
    });

    test('domain error code is service_unavailable when all packages fail', () async {
      final result = await buildHandler().call(_request(['unknown1', 'unknown2']));

      expect(_errorInner(result)['code'], equals(DomainErrors.serviceUnavailable));
    });

    test('domain error includes a suggestion when all packages fail', () async {
      final result = await buildHandler().call(_request(['unknown1', 'unknown2']));

      expect(_errorInner(result), contains('suggestion'));
    });
  });

  // ─── Concurrent fetching ──────────────────────────────────────────────────────

  group('concurrent fetching', () {
    test(
      'issues package fetches concurrently (more than one package in flight)',
      () async {
        // Gate the info endpoint of each package on a shared completer so every
        // package parks its fetch in flight. Score/documentation resolve
        // immediately, so each package contributes exactly one parked request —
        // peak in-flight therefore counts overlapping *packages*. A sequential
        // await-in-a-loop regression would hold peak at 1.
        const names = ['http', 'dio', 'shelf'];
        final gate = Completer<void>();
        var inFlight = 0;
        var peak = 0;
        for (final name in names) {
          _stubUrl(
            mock: mockHttp,
            urlFragment: '/documentation/$name/latest/',
            response: _notFound(),
          );
          when(
            () => mockHttp.get(
              any(that: predicate<Uri>((u) => u.toString().endsWith('/api/packages/$name'))),
              headers: any(named: 'headers'),
            ),
          ).thenAnswer((_) async {
            inFlight++;
            if (inFlight > peak) peak = inFlight;
            await gate.future;
            inFlight--;
            return _ok(_packageInfoJson(name));
          });
          _stubUrl(
            mock: mockHttp,
            urlFragment: '/api/packages/$name/score',
            response: _ok(_packageScoreJson()),
          );
        }

        final future = buildHandler().call(_request(names));
        // Let the concurrent fetches reach the wire and park on the gate.
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(
          peak,
          greaterThan(1),
          reason: 'multiple packages should be fetched at once, not one at a time',
        );

        gate.complete();
        await future; // Drain so no futures outlive the test.
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'output order matches input order even when a later package resolves first',
      () async {
        // 'aaa' is gated so it cannot finish until we release it; 'zzz' resolves
        // immediately. This forces out-of-order completion (zzz before aaa) while
        // 'aaa' precedes 'zzz' in the input.
        final aaaGate = _stubGatedInfo(mockHttp, 'aaa');
        _stubSuccess(mockHttp, 'zzz');

        final future = buildHandler().call(_request(['aaa', 'zzz']));
        // Give 'zzz' the chance to complete ahead of the still-gated 'aaa'.
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        aaaGate.complete();

        final result = await future;

        expect(_payload(result)['packages'], equals(['aaa', 'zzz']));
        // The matrix is keyed by field; each field's inner map is folded in
        // request order, so package columns stay in input order regardless of
        // which package's fetch completed first.
        final nameColumn = _matrixOf(result)['name']! as Map<String, Object?>;
        expect(nameColumn.keys.toList(), equals(['aaa', 'zzz']));
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );
  });

  // ─── Cache hit ───────────────────────────────────────────────────────────────

  group('cache hit', () {
    test('does not issue a second HTTP request for a package already in cache', () async {
      _stubSuccess(mockHttp, 'http');
      _stubSuccess(mockHttp, 'dio');

      await buildHandler().call(_request(['http', 'dio']));
      await buildHandler().call(_request(['http', 'dio']));

      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/api/packages/http/score'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('reuses a package cached by a prior get_package call', () async {
      // A prior get_package call for 'http' warms the shared packageDetail
      // facade; compare_packages must reuse that entry rather than re-fetch,
      // exercising the same (name, version)-anchored cache both handlers share.
      _stubSuccess(mockHttp, 'http');
      _stubSuccess(mockHttp, 'dio');

      final getPackageHandler = GetPackageHandler(
        client: client,
        packageDetail: packageDetail,
        log: (level, data) {},
      );
      await getPackageHandler.call(
        CallToolRequest(name: 'get_package', arguments: {'name': 'http'}),
      );

      await buildHandler().call(_request(['http', 'dio']));

      // Exactly one score fetch for 'http' — from the prior get_package call —
      // proves compare_packages did not re-fetch it.
      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) => u.toString().contains('/api/packages/http/score'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });
  });

  // ─── Fixture smoke test ───────────────────────────────────────────────────────

  group('fixture smoke test', () {
    test('pubPoints from the http fixture are reflected in the matrix', () async {
      _stubUrl(
        mock: mockHttp,
        urlFragment: '/documentation/http/latest/',
        response: _notFound(),
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
      _stubSuccess(mockHttp, 'dio');

      final result = await buildHandler().call(_request(['http', 'dio']));
      final pubPoints = _matrixOf(result)['pubPoints']! as Map<String, Object?>;

      expect(pubPoints['http'], equals(160));
    });
  });
}
