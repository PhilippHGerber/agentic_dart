/// Unit tests for [GetSdkReleaseNotesHandler].
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dart_mcp/server.dart';
import 'package:dart_pubdev_mcp/src/cache/cache_registry.dart';
import 'package:dart_pubdev_mcp/src/cache/tarball_disk_cache.dart';
import 'package:dart_pubdev_mcp/src/data/domain_error.dart';
import 'package:dart_pubdev_mcp/src/data/pub_client.dart';
import 'package:dart_pubdev_mcp/src/data/sdk_client.dart';
import 'package:dart_pubdev_mcp/src/tools/get_sdk_release_notes.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';

// ─── Fixtures ─────────────────────────────────────────────────────────────────

const _dartChangelogMarkdown = '''
# Dart SDK Changelog

## 3.14.0 - 2025-01-15

### Libraries

#### dart:ffi
- Added NativeFinalizer.callback support.
- Fixed struct allocation leak.

### Tools

#### Formatter
- Don't crash on invalid pattern syntax.

## 3.13.0 - 2024-11-20

### Language
- Added new language feature.

### Breaking changes
- **Breaking Change**: Removed deprecated API `foo()`.

## 3.12.0

### Tools
- Compiler performance improvements.

## 3.11.0

### Core libraries
- Added minor helper methods.

## 3.10.0

### Core libraries
- Initial 3.10 baseline.

## 3.9.0

### Language
- Old version baseline.
''';

const _flutterChangelogMarkdown = '''
# Flutter Changelog

## 3.24.1 (2024-08-06)

### Hotfixes
- Fixes #12345: engine crash on iOS.

## 3.24.0 (2024-08-01)

### Framework
- Updated scrollbar theme defaults.

### Engine
- Impeller Vulkan backend improvements.
''';

// ─── Helpers ──────────────────────────────────────────────────────────────────

CallToolRequest _request(Map<String, Object?> args) =>
    CallToolRequest(name: 'get_sdk_release_notes', arguments: args);

Map<String, Object?> _payload(CallToolResult result) {
  return jsonDecode((result.content.first as TextContent).text) as Map<String, Object?>;
}

List<Map<String, Object?>> _entries(CallToolResult result) {
  final json = _payload(result);
  return ((json['entries'] as List<Object?>?) ?? const []).cast<Map<String, Object?>>();
}

String? _resolvedVersion(CallToolResult result) {
  return _payload(result)['resolvedVersion'] as String?;
}

Map<String, Object?> _errorPayload(CallToolResult result) {
  final outer = _payload(result);
  final inner = outer['error'];
  if (inner is! Map<String, Object?>) throw StateError('No nested error object');
  return inner;
}

List<int> _createSdkTarballWithChangelog(String changelogContent, {bool wrapInSdk = false}) {
  final archive = Archive();
  final path = wrapInSdk ? 'sdk-3.14.0/sdk/CHANGELOG.md' : 'flutter-3.24.1/CHANGELOG.md';
  final bytes = utf8.encode(changelogContent);
  archive.addFile(ArchiveFile(path, bytes.length, bytes));
  final tarBytes = TarEncoder().encode(archive);
  return const GZipEncoder().encode(tarBytes);
}

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(() {
    registerFallbackValue(Uri.parse('https://pub.dev'));
    registerFallbackValue(http.Request('GET', Uri.parse('https://pub.dev')));
  });

  late Directory tempDir;
  late TarballDiskCache tarballCache;
  late MockHttpClient mockHttp;
  late SdkClient sdkClient;
  late CacheRegistry registry;
  final loggedMessages = <(LoggingLevel, Object)>[];

  GetSdkReleaseNotesHandler buildHandler() => GetSdkReleaseNotesHandler(
    sdkChangelog: registry.sdkChangelog,
    log: (level, data) => loggedMessages.add((level, data)),
  );

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sdk_release_notes_test_');
    tarballCache = TarballDiskCache(directoryPath: tempDir.path);
    mockHttp = MockHttpClient();
    final pubClient = PubDevClient(
      httpClient: mockHttp,
      retryPolicy: instantRetryPolicy,
    );
    sdkClient = SdkClient(
      httpClient: mockHttp,
      retryPolicy: instantRetryPolicy,
      tarballCache: tarballCache,
    );
    registry = CacheRegistry(
      client: pubClient,
      sdkClient: sdkClient,
    );
    loggedMessages.clear();
  });

  tearDown(() {
    registry.dispose();
    try {
      tempDir.deleteSync(recursive: true);
    } on Object catch (_) {}
  });

  group('input validation', () {
    test('returns INVALID_ARGUMENT when sdk is missing or invalid', () async {
      final result = await buildHandler().call(_request({'sdk': 'unknown'}));

      expect(result.isError, isTrue);
      final error = _errorPayload(result);
      expect(error['code'], equals(DomainErrors.invalidArgument));
      expect(error['message'], contains('unknown'));
    });

    test('returns INVALID_ARGUMENT when limit is <= 0', () async {
      final result = await buildHandler().call(_request({'sdk': 'dart', 'limit': 0}));

      expect(result.isError, isTrue);
      final error = _errorPayload(result);
      expect(error['code'], equals(DomainErrors.invalidArgument));
    });

    test('returns INVALID_ARGUMENT when fromVersion is newer than target version', () async {
      stubUrl(
        mock: mockHttp,
        urlFragment: 'dart-lang/sdk/main/CHANGELOG.md',
        response: ok(_dartChangelogMarkdown),
      );

      final result = await buildHandler().call(
        _request({
          'sdk': 'dart',
          'version': '3.12.0',
          'fromVersion': '3.14.0',
        }),
      );

      expect(result.isError, isTrue);
      final error = _errorPayload(result);
      expect(error['code'], equals(DomainErrors.invalidArgument));
    });
  });

  group('Dart SDK release notes', () {
    setUp(() {
      stubUrl(
        mock: mockHttp,
        urlFragment: 'dart-lang/sdk/main/CHANGELOG.md',
        response: ok(_dartChangelogMarkdown),
      );
    });

    test('anchors to newest release with limit=1 default when version is omitted', () async {
      final result = await buildHandler().call(_request({'sdk': 'dart'}));

      expect(result.isError, isNull);
      expect(_resolvedVersion(result), equals('3.14.0'));

      final entries = _entries(result);
      expect(entries.length, equals(1));
      expect(entries[0]['version'], equals('3.14.0'));
      expect(entries[0]['date'], equals('2025-01-15T00:00:00.000Z'));
      expect(entries[0]['breaking'], isFalse);

      final sections = (entries[0]['sections'] as Map<String, Object?>?) ?? {};
      expect(sections['Libraries'], isList);
      expect(sections['Tools'], isList);

      final changes = (entries[0]['changes'] as List<Object?>?) ?? [];
      expect(changes, contains('dart:ffi: Added NativeFinalizer.callback support.'));
      expect(changes, contains("Formatter: Don't crash on invalid pattern syntax."));
    });

    test('retrieves specific past version and detects breaking flag', () async {
      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'version': '3.13.0'}),
      );

      expect(result.isError, isNull);
      expect(_resolvedVersion(result), equals('3.13.0'));

      final entries = _entries(result);
      expect(entries.length, equals(1));
      expect(entries[0]['version'], equals('3.13.0'));
      expect(entries[0]['breaking'], isTrue);
      expect(entries[0]['changes'], contains('Added new language feature.'));
    });

    test('applies fromVersion with default limit 5', () async {
      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'fromVersion': '3.9.0'}),
      );

      expect(result.isError, isNull);
      expect(_resolvedVersion(result), equals('3.14.0'));

      final entries = _entries(result);
      // Releases newer than 3.9.0 are 3.14.0, 3.13.0, 3.12.0, 3.11.0, 3.10.0 (5 total)
      expect(entries.length, equals(5));
      expect(entries.map((e) => e['version']), equals([
        '3.14.0',
        '3.13.0',
        '3.12.0',
        '3.11.0',
        '3.10.0',
      ]));
    });

    test('respects explicit limit override', () async {
      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'limit': 3}),
      );

      expect(result.isError, isNull);
      final entries = _entries(result);
      expect(entries.length, equals(3));
      expect(entries.map((e) => e['version']), equals(['3.14.0', '3.13.0', '3.12.0']));
    });

    test('returns SDK_VERSION_NOT_FOUND for non-existent target version', () async {
      final result = await buildHandler().call(
        _request({'sdk': 'dart', 'version': '9.9.9'}),
      );

      expect(result.isError, isTrue);
      final error = _errorPayload(result);
      expect(error['code'], equals(DomainErrors.sdkVersionNotFound));
      expect(error['message'], contains('9.9.9'));
    });
  });

  group('Flutter SDK release notes', () {
    setUp(() {
      stubUrl(
        mock: mockHttp,
        urlFragment: 'flutter/flutter/master/CHANGELOG.md',
        response: ok(_flutterChangelogMarkdown),
      );
    });

    test('retrieves Flutter hotfix release and sections', () async {
      final result = await buildHandler().call(_request({'sdk': 'flutter'}));

      expect(result.isError, isNull);
      expect(_resolvedVersion(result), equals('3.24.1'));

      final entries = _entries(result);
      expect(entries.length, equals(1));
      expect(entries[0]['version'], equals('3.24.1'));
      expect(entries[0]['date'], equals('2024-08-06T00:00:00.000Z'));

      final sections = (entries[0]['sections'] as Map<String, Object?>?) ?? {};
      expect(sections['Hotfixes'], equals(['Fixes #12345: engine crash on iOS.']));
    });
  });

  group('tarball disk cache fallback', () {
    test('falls back to locally cached tarball when network request fails', () async {
      // Simulate network 503 failure
      stubUrl(
        mock: mockHttp,
        urlFragment: 'dart-lang/sdk/main/CHANGELOG.md',
        response: http.Response('Service Unavailable', 503),
      );

      // Pre-seed disk cache with SDK tarball containing CHANGELOG.md
      final tarballBytes = _createSdkTarballWithChangelog(_dartChangelogMarkdown, wrapInSdk: true);
      await tarballCache.write('dart_sdk', '3.14.0', tarballBytes);

      final result = await buildHandler().call(_request({'sdk': 'dart'}));

      expect(result.isError, isNull);
      expect(_resolvedVersion(result), equals('3.14.0'));

      final entries = _entries(result);
      expect(entries.length, equals(1));
      expect(entries[0]['version'], equals('3.14.0'));
    });

    test('returns SERVICE_UNAVAILABLE when network fails and no cached tarball exists', () async {
      stubUrl(
        mock: mockHttp,
        urlFragment: 'dart-lang/sdk/main/CHANGELOG.md',
        response: http.Response('Service Unavailable', 503),
      );

      final result = await buildHandler().call(_request({'sdk': 'dart'}));

      expect(result.isError, isTrue);
      final error = _errorPayload(result);
      expect(error['code'], equals(DomainErrors.serviceUnavailable));
    });
  });
}
