/// Unit tests for [GetPackageHandler].
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:dart_pubdev_mcp/src/cache/cache_registry.dart';
import 'package:dart_pubdev_mcp/src/cache/keyed_cache.dart';
import 'package:dart_pubdev_mcp/src/data/domain_error.dart';
import 'package:dart_pubdev_mcp/src/data/models.dart';
import 'package:dart_pubdev_mcp/src/tools/get_package.dart';
import 'package:dart_pubdev_mcp/src/tools/tool_definitions.dart' show getPackageTool;
import 'package:dart_pubdev_mcp/src/tools/version_resolver.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';
import '../../support/schema_conformance.dart';

// ─── Helpers ──────────────────────────────────────────────────────────────────

/// One advisory affecting versions `< 0.13.3` — mirrors the live `http`
/// GHSA-4rgh-jx4f-qfcq advisory also used by `get_security_advisories_test.dart`.
const _oneAdvisoryBody = '''
{
  "advisories": [
    {
      "id": "GHSA-4rgh-jx4f-qfcq",
      "aliases": ["CVE-2020-35669"],
      "summary": "http before 0.13.3 vulnerable to header injection",
      "affected": [
        {
          "package": {"ecosystem": "Pub", "name": "http"},
          "ranges": [
            {"type": "ECOSYSTEM", "events": [{"introduced": "0"}, {"fixed": "0.13.3"}]}
          ]
        }
      ],
      "database_specific": {"pub_display_url": "https://github.com/advisories/GHSA-4rgh-jx4f-qfcq"}
    }
  ],
  "advisoriesUpdated": "2026-05-04T16:03:47.124153Z"
}
''';

/// Stubs the three endpoints for a successful `get_package` call (latest version).
///
/// The more specific `/score` stub is registered last so it wins over the
/// broader `/api/packages/http` stub (see [stubUrl] for why order matters).
void _stubSuccess(MockHttpClient mock) {
  stubUrl(
    mock: mock,
    urlFragment: '/documentation/http/latest/',
    response: notFound(),
  );
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

/// Stubs the two endpoints for a version-pinned `get_package` call.
void _stubVersionSuccess(MockHttpClient mock, String version) {
  final versionData = jsonDecode(readFixture('package_info.json')) as Map<String, Object?>;
  final latestData = versionData['latest']! as Map<String, Object?>;

  stubUrl(
    mock: mock,
    urlFragment: '/api/packages/http/versions/$version',
    response: ok(jsonEncode(latestData)),
  );
  stubUrl(
    mock: mock,
    urlFragment: '/api/packages/http/score',
    response: ok(readFixture('package_score.json')),
  );
}

/// Creates a [CallToolRequest] for `get_package` with the given [args].
CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'get_package', arguments: args);

/// Decodes the first content item of [result] as a JSON map.
Map<String, Object?> _detail(CallToolResult result) =>
    jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;

/// Returns the `resolvedVersion` field of the success [result].
String? _resolvedVersion(CallToolResult result) => _detail(result)['resolvedVersion'] as String?;

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
  late KeyedCache<PackageDetailId, PackageDetail> packageDetail;
  final loggedMessages = <(LoggingLevel, Object)>[];

  GetPackageHandler buildHandler() => GetPackageHandler(
    versionResolver: versionResolver,
    packageDetail: packageDetail,
    securityAdvisories: stack.caches.securityAdvisories,
    log: (level, data) => loggedMessages.add((level, data)),
  );

  setUp(() {
    fakeNow = DateTime(2026, 5, 12);
    stack = TestStack(clock: () => fakeNow);
    mockHttp = stack.http;
    versionResolver = VersionResolver(
      client: stack.client,
      log: (level, data) => loggedMessages.add((level, data)),
    );
    packageDetail = stack.caches.packageDetail;
    loggedMessages.clear();
  });

  tearDown(() => stack.close());

  // ─── Successful fetch (latest) ────────────────────────────────────────────────

  group('successful fetch for latest version', () {
    test('returns a JSON object without isError set', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(result.isError, isNull);
    });

    test('result contains the package name', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_detail(result)['package'], equals('http'));
      expect(_detail(result).containsKey('name'), isFalse);
    });

    test('structuredContent conforms to the declared outputSchema', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expectConformsToOutputSchema(getPackageTool, result.structuredContent);
    });

    test('result contains the version field', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_detail(result)['version'], equals('1.6.0'));
    });

    test('result contains the description field', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_detail(result)['description'], isNotEmpty);
    });

    test('result contains activeMaintenance field', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_detail(result), contains('activeMaintenance'));
    });

    test('result contains likes from score', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_detail(result)['likes'], equals(8435));
    });

    test('result contains pubPoints from score', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_detail(result)['pubPoints'], equals(160));
    });

    test('result contains sdkConstraints with dart field', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));
      final constraints = _detail(result)['sdkConstraints']! as Map<String, Object?>;

      expect(constraints, contains('dart'));
    });

    test('result contains platforms list', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_detail(result)['platforms'], isA<List<Object?>>());
    });

    test('result contains dependencies map', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_detail(result)['dependencies'], isA<Map<String, Object?>>());
    });

    test('result contains devDependencies map', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_detail(result)['devDependencies'], isA<Map<String, Object?>>());
    });

    test('result contains versionsRecent as a list', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_detail(result)['versionsRecent'], isA<List<Object?>>());
    });

    test('versionsRecent contains at most five entries', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));
      final versions = _detail(result)['versionsRecent']! as List<Object?>;

      expect(versions.length, lessThanOrEqualTo(5));
    });

    test('versionsRecent is ordered newest-first', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));
      final versions = (_detail(result)['versionsRecent']! as List<Object?>).cast<String>();

      expect(versions.first, equals('1.6.0'));
    });

    test('result contains publisher from score tags', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_detail(result)['publisher'], equals('dart.dev'));
    });

    test('result contains license from score tags', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_detail(result)['license'], isNotNull);
    });

    test('result contains isFlutterFavorite field', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_detail(result), contains('isFlutterFavorite'));
    });

    test('result contains repository from pubspec', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_detail(result)['repository'], isNotNull);
    });
  });

  // ─── readmeExcerpt ────────────────────────────────────────────────────────────

  group('readmeExcerpt', () {
    test('is absent when the docs page returns 404', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_detail(result).containsKey('readmeExcerpt'), isFalse);
    });

    test('is present and non-empty when the docs page returns valid HTML', () async {
      const html = '<div class="desc markdown"><p>A great HTTP library.</p></div>';
      stubUrl(
        mock: mockHttp,
        urlFragment: '/documentation/http/latest/',
        response: ok(html),
      );
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http',
        response: ok(readFixture('package_info.json')),
      );
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http/score',
        response: ok(readFixture('package_score.json')),
      );

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_detail(result)['readmeExcerpt'], isNotEmpty);
    });
  });

  // ─── advisories summary (ticket 03) ───────────────────────────────────────────

  group('advisories summary', () {
    test('is present with count/ids/affectsResolvedVersion on a successful fetch', () async {
      _stubSuccess(mockHttp);
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http/advisories',
        response: ok(_oneAdvisoryBody),
      );

      final result = await buildHandler().call(_request({'package': 'http'}));
      final advisories = _detail(result)['advisories']! as Map<String, Object?>;

      expect(advisories['count'], equals(1));
      expect(advisories['ids'], equals(['GHSA-4rgh-jx4f-qfcq']));
      // Resolved version (1.6.0) is past the fix (0.13.3).
      expect(advisories['affectsResolvedVersion'], isFalse);
    });

    test('affectsResolvedVersion is true when the resolved version is in range', () async {
      _stubVersionSuccess(mockHttp, '0.12.0');
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http/advisories',
        response: ok(_oneAdvisoryBody),
      );

      final result = await buildHandler().call(
        _request({'package': 'http', 'version': '0.12.0'}),
      );
      final advisories = _detail(result)['advisories']! as Map<String, Object?>;

      expect(advisories['affectsResolvedVersion'], isTrue);
    });

    test('count is zero when the package has no advisories', () async {
      _stubSuccess(mockHttp);
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http/advisories',
        response: ok('{"advisories": [], "advisoriesUpdated": "1970-01-01T00:00:00.000"}'),
      );

      final result = await buildHandler().call(_request({'package': 'http'}));
      final advisories = _detail(result)['advisories']! as Map<String, Object?>;

      expect(advisories['count'], equals(0));
      expect(advisories['ids'], isEmpty);
      expect(advisories['affectsResolvedVersion'], isFalse);
    });

    test('is omitted (not a Tool Error) when the advisories fetch fails', () async {
      _stubSuccess(mockHttp);
      // Registered after _stubSuccess so it wins over the broader
      // '/api/packages/http' stub, which would otherwise also match this URL.
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http/advisories',
        response: notFound(),
      );

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(result.isError, isNull);
      expect(_detail(result).containsKey('advisories'), isFalse);
    });

    test(
      'structuredContent conforms to the declared outputSchema with advisories present',
      () async {
        _stubSuccess(mockHttp);
        stubUrl(
          mock: mockHttp,
          urlFragment: '/api/packages/http/advisories',
          response: ok(_oneAdvisoryBody),
        );

        final result = await buildHandler().call(_request({'package': 'http'}));

        expectConformsToOutputSchema(getPackageTool, result.structuredContent);
      },
    );
  });

  // ─── Version-pinned fetch ─────────────────────────────────────────────────────

  group('version-pinned fetch', () {
    test('fetches from the versions endpoint when version is supplied', () async {
      _stubVersionSuccess(mockHttp, '1.5.0');

      await buildHandler().call(_request({'package': 'http', 'version': '1.5.0'}));

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
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http/advisories',
        response: notFound(),
      );

      await buildHandler().call(_request({'package': 'http', 'version': '1.5.0'}));

      verifyNever(
        () => mockHttp.get(
          any(
            that: predicate<Uri>(
              (u) =>
                  u.toString().contains('/api/packages/http') &&
                  !u.toString().contains('/score') &&
                  !u.toString().contains('/versions/') &&
                  !u.toString().contains('/advisories'),
            ),
          ),
          headers: any(named: 'headers'),
        ),
      );
    });

    test('returns a valid result for a version-pinned request', () async {
      _stubVersionSuccess(mockHttp, '1.5.0');

      final result = await buildHandler().call(_request({'package': 'http', 'version': '1.5.0'}));

      expect(result.isError, isNull);
      expect(_detail(result)['package'], equals('http'));
    });
  });

  // ─── resolvedVersion (P1.12) ──────────────────────────────────────────────────

  group('resolvedVersion', () {
    test('equals the resolved latest stable version when version is omitted', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_resolvedVersion(result), equals('1.6.0'));
    });

    test('echoes the supplied version on a pinned request', () async {
      _stubVersionSuccess(mockHttp, '1.5.0');

      final result = await buildHandler().call(_request({'package': 'http', 'version': '1.5.0'}));

      expect(_resolvedVersion(result), equals('1.5.0'));
    });
  });

  // ─── Cache hit ──────────────────────────────────────────────────────────────

  group('cache hit', () {
    test('does not issue a second HTTP request within the TTL window', () async {
      _stubSuccess(mockHttp);
      final handler = buildHandler();

      await handler.call(_request({'package': 'http'}));
      fakeNow = fakeNow.add(const Duration(minutes: 14));
      await handler.call(_request({'package': 'http'}));

      // First call: resolve (1) + getPackage (2) + score (3) + advisories (4).
      // Second call: resolve (5) + cache hit for packageDetail and
      // securityAdvisories both (no further fetch).
      verify(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('/api/packages/http'))),
          headers: any(named: 'headers'),
        ),
      ).called(5);
    });

    test('fetches version-pinned requests independently of the latest entry', () async {
      _stubSuccess(mockHttp);
      _stubVersionSuccess(mockHttp, '1.5.0');
      final handler = buildHandler();

      await handler.call(_request({'package': 'http'}));
      await handler.call(_request({'package': 'http', 'version': '1.5.0'}));

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
    test('logs an info message containing the package name', () async {
      _stubSuccess(mockHttp);

      await buildHandler().call(_request({'package': 'http'}));

      final infoLogs = loggedMessages
          .where((m) => m.$1 == LoggingLevel.info)
          .map((m) => m.$2.toString());
      expect(infoLogs.any((m) => m.contains('package=http')), isTrue);
    });
  });

  // ─── 404 / package not found ─────────────────────────────────────────────────

  group('package not found', () {
    test('returns a domain error when the package endpoint returns 404', () async {
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/unknown',
        response: notFound(),
      );

      final result = await buildHandler().call(_request({'package': 'unknown'}));

      expect(result.isError, isTrue);
    });

    test('domain error code is package_not_found on 404', () async {
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/unknown',
        response: notFound(),
      );

      final result = await buildHandler().call(_request({'package': 'unknown'}));

      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));
    });

    test('domain error contains a suggestion on 404', () async {
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/unknown',
        response: notFound(),
      );

      final result = await buildHandler().call(_request({'package': 'unknown'}));

      expect(_errorPayload(result), contains('suggestion'));
    });

    test('error result is not cached so the next call retries the HTTP request', () async {
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/unknown',
        response: notFound(),
      );
      final handler = buildHandler();

      await handler.call(_request({'package': 'unknown'}));
      await handler.call(_request({'package': 'unknown'}));

      verify(
        () => mockHttp.get(
          any(that: predicate<Uri>((u) => u.toString().contains('/api/packages/unknown'))),
          headers: any(named: 'headers'),
        ),
      ).called(greaterThan(1));
    });

    test('returns a domain error when the version endpoint returns 404', () async {
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http/versions/9.9.9',
        response: notFound(),
      );
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http/score',
        response: ok(readFixture('package_score.json')),
      );

      final result = await buildHandler().call(
        _request({'package': 'http', 'version': '9.9.9'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));
    });
  });

  group('SDK package guard', () {
    test('rejects an SDK package name with no version supplied', () async {
      final result = await buildHandler().call(_request({'package': 'flutter'}));

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));
      verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
    });

    test('rejects an SDK package name even with an explicit version', () async {
      final result = await buildHandler().call(
        _request({'package': 'flutter', 'version': '3.35.0'}),
      );

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));
      verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
    });
  });
}
