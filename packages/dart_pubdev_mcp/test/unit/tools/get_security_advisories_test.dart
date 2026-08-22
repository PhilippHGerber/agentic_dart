/// Unit tests for [GetSecurityAdvisoriesHandler].
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:dart_pubdev_mcp/src/cache/cache_registry.dart';
import 'package:dart_pubdev_mcp/src/data/domain_error.dart';
import 'package:dart_pubdev_mcp/src/tools/get_security_advisories.dart';
import 'package:dart_pubdev_mcp/src/tools/version_resolver.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';
import '../../support/pub_stubs.dart';

// ─── Helpers ──────────────────────────────────────────────────────────────────

/// One advisory affecting versions `< 0.13.3` — mirrors the live `http`
/// GHSA-4rgh-jx4f-qfcq advisory verified in the disposition Plan.
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

const _noAdvisoriesBody = '{"advisories": [], "advisoriesUpdated": "1970-01-01T00:00:00.000"}';

/// Stubs a successful advisories fetch plus version resolution for [name].
void _stubSuccess(MockHttpClient mock, {String name = 'http', String? body}) {
  stubPackageInfo(mock, packageName: name);
  stubUrl(
    mock: mock,
    urlFragment: '/api/packages/$name/advisories',
    response: ok(body ?? _oneAdvisoryBody),
  );
}

CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'get_security_advisories', arguments: args);

Map<String, Object?> _decode(CallToolResult result) =>
    jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;

List<Map<String, Object?>> _affecting(CallToolResult result) =>
    ((_decode(result)['affecting'] as List<Object?>?) ?? const []).cast<Map<String, Object?>>();

List<Map<String, Object?>> _other(CallToolResult result) =>
    ((_decode(result)['other'] as List<Object?>?) ?? const []).cast<Map<String, Object?>>();

String? _resolvedVersion(CallToolResult result) => _decode(result)['resolvedVersion'] as String?;

Map<String, Object?> _errorPayload(CallToolResult result) {
  final inner = _decode(result)['error'];
  if (inner is! Map<String, Object?>) throw StateError('No nested error object');
  return inner;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late TestStack stack;
  late MockHttpClient mockHttp;
  late VersionResolver versionResolver;
  late DateTime fakeNow;
  late CacheRegistry registry;
  final loggedMessages = <(LoggingLevel, Object)>[];

  GetSecurityAdvisoriesHandler buildHandler() => GetSecurityAdvisoriesHandler(
    versionResolver: versionResolver,
    securityAdvisories: registry.securityAdvisories,
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
    registry = stack.caches;
    loggedMessages.clear();
  });

  tearDown(() => stack.close());

  // ─── package echo ──────────────────────────────────────────────────────────

  group('package echo', () {
    test('is present and echoes the requested package name', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_decode(result)['package'], equals('http'));
    });
  });

  // ─── resolvedVersion ────────────────────────────────────────────────────────

  group('resolvedVersion', () {
    test('is present and equals the resolved latest stable version', () async {
      _stubSuccess(mockHttp);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(_resolvedVersion(result), equals('1.6.0'));
    });

    test('equals the caller-supplied version when one is given', () async {
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http/advisories',
        response: ok(_oneAdvisoryBody),
      );

      final result = await buildHandler().call(_request({'package': 'http', 'version': '0.10.0'}));

      expect(_resolvedVersion(result), equals('0.10.0'));
    });
  });

  // ─── Version-aware split ────────────────────────────────────────────────────

  group('affecting vs other split', () {
    test('a version before the fix goes into affecting', () async {
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http/advisories',
        response: ok(_oneAdvisoryBody),
      );

      final result = await buildHandler().call(_request({'package': 'http', 'version': '0.12.0'}));

      expect(_affecting(result), hasLength(1));
      expect(_other(result), isEmpty);
    });

    test('a version at or after the fix goes into other', () async {
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http/advisories',
        response: ok(_oneAdvisoryBody),
      );

      final result = await buildHandler().call(_request({'package': 'http', 'version': '1.0.0'}));

      expect(_affecting(result), isEmpty);
      expect(_other(result), hasLength(1));
    });

    test('affecting entry carries id, aliases, summary, url, and affectedRanges', () async {
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http/advisories',
        response: ok(_oneAdvisoryBody),
      );

      final result = await buildHandler().call(_request({'package': 'http', 'version': '0.12.0'}));
      final entry = _affecting(result).single;

      expect(entry['id'], equals('GHSA-4rgh-jx4f-qfcq'));
      expect(entry['aliases'], equals(['CVE-2020-35669']));
      expect(entry['summary'], contains('header injection'));
      expect(entry['url'], equals('https://github.com/advisories/GHSA-4rgh-jx4f-qfcq'));
      expect(entry['affectedRanges'], isNotEmpty);
    });

    test('the same cached advisory list re-evaluates differently per supplied version', () async {
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http/advisories',
        response: ok(_oneAdvisoryBody),
      );
      final handler = buildHandler();

      final affected = await handler.call(_request({'package': 'http', 'version': '0.12.0'}));
      final fixed = await handler.call(_request({'package': 'http', 'version': '1.0.0'}));

      expect(_affecting(affected), hasLength(1));
      expect(_affecting(fixed), isEmpty);
    });
  });

  // ─── Zero advisories ────────────────────────────────────────────────────────

  group('zero advisories', () {
    test('succeeds (not a Tool Error) with both lists empty', () async {
      _stubSuccess(mockHttp, body: _noAdvisoriesBody);

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(result.isError, isNull);
      expect(_affecting(result), isEmpty);
      expect(_other(result), isEmpty);
    });
  });

  // ─── Package not found ──────────────────────────────────────────────────────

  group('package not found', () {
    test('propagates package_not_found when version resolution returns 404', () async {
      stubUrl(mock: mockHttp, urlFragment: '/api/packages/http', response: notFound());

      final result = await buildHandler().call(_request({'package': 'http'}));

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));
    });

    test('does not fetch advisories when version resolution fails', () async {
      stubUrl(mock: mockHttp, urlFragment: '/api/packages/http', response: notFound());

      await buildHandler().call(_request({'package': 'http'}));

      verifyNever(
        () => mockHttp.get(
          any(
            that: predicate<Uri>((u) => u.toString().contains('/api/packages/http/advisories')),
          ),
          headers: any(named: 'headers'),
        ),
      );
    });

    test('propagates package_not_found when the advisories endpoint 404s', () async {
      stubPackageInfo(mockHttp, packageName: 'unknown');
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/unknown/advisories',
        response: notFound(),
      );

      final result = await buildHandler().call(_request({'package': 'unknown'}));

      expect(result.isError, isTrue);
      expect(_errorPayload(result)['code'], equals(DomainErrors.packageNotFound));
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

      verify(
        () => mockHttp.get(
          any(
            that: predicate<Uri>((u) => u.toString().contains('/api/packages/http/advisories')),
          ),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });
  });

  // ─── Logging ────────────────────────────────────────────────────────────────

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
}
