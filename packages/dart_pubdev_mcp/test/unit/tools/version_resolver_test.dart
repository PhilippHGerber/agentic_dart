/// Unit tests for [VersionResolver].
library;

import 'package:dart_mcp/server.dart';
import 'package:dart_pubdev_mcp/src/data/domain_error.dart';
import 'package:dart_pubdev_mcp/src/tools/version_resolver.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late TestStack stack;
  late MockHttpClient mockHttp;
  final loggedMessages = <(LoggingLevel, Object)>[];

  VersionResolver buildResolver() => VersionResolver(
    client: stack.client,
    log: (level, data) => loggedMessages.add((level, data)),
  );

  setUp(() {
    stack = TestStack();
    mockHttp = stack.http;
    loggedMessages.clear();
  });

  tearDown(() => stack.close());

  group('supplied version', () {
    test('short-circuits to the supplied value', () async {
      final result = await buildResolver().resolve(
        package: 'http',
        supplied: '1.5.0',
        tool: 'get_package',
      );

      expect(result, isA<PubDevSuccess<String>>());
      expect((result as PubDevSuccess<String>).value, equals('1.5.0'));
    });

    test('never calls the client', () async {
      await buildResolver().resolve(package: 'http', supplied: '1.5.0', tool: 'get_package');

      verifyNever(
        () => mockHttp.get(any(), headers: any(named: 'headers')),
      );
    });

    test('does not log', () async {
      await buildResolver().resolve(package: 'http', supplied: '1.5.0', tool: 'get_package');

      expect(loggedMessages, isEmpty);
    });
  });

  group('absent version', () {
    test('resolves via the latest stable version', () async {
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http',
        response: ok(readFixture('package_info.json')),
      );

      final result = await buildResolver().resolve(package: 'http', tool: 'get_package');

      expect(result, isA<PubDevSuccess<String>>());
      expect((result as PubDevSuccess<String>).value, equals('1.6.0'));
    });

    test('logs the resolving line prefixed with tool', () async {
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http',
        response: ok(readFixture('package_info.json')),
      );

      await buildResolver().resolve(package: 'http', tool: 'get_package');

      expect(
        loggedMessages,
        contains((LoggingLevel.info, 'get_package: resolving latest stable version for http')),
      );
    });

    test('logs the resolved line prefixed with tool', () async {
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http',
        response: ok(readFixture('package_info.json')),
      );

      await buildResolver().resolve(package: 'http', tool: 'get_package');

      expect(
        loggedMessages,
        contains((LoggingLevel.debug, 'get_package: resolved version=1.6.0')),
      );
    });
  });

  group('resolution failure', () {
    test('passes the PubDevFailure through', () async {
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/unknown',
        response: notFound(),
      );

      final result = await buildResolver().resolve(package: 'unknown', tool: 'get_package');

      expect(result, isA<PubDevFailure<String>>());
      expect(
        (result as PubDevFailure<String>).error.code,
        equals(DomainErrors.packageNotFound),
      );
    });
  });
}
