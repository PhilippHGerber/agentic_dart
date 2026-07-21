/// Unit tests for [SdkClient] and [resolveDartSdkRef].
library;

import 'dart:io';

import 'package:dart_pubdev_mcp/src/cache/tarball_disk_cache.dart';
import 'package:dart_pubdev_mcp/src/data/domain_error.dart';
import 'package:dart_pubdev_mcp/src/data/sdk_client.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';
import '../../support/pub_stubs.dart';

const _files = {
  'sdk/lib/core/list.dart': 'class List {}\n',
  'sdk/lib/core/uri.dart': 'class Uri {}\n',
  'README.md': '# Dart SDK',
};

void main() {
  // ─── resolveDartSdkRef ──────────────────────────────────────────────────────

  group('resolveDartSdkRef', () {
    test('takes the leading token of a stable Platform.version string', () {
      expect(
        resolveDartSdkRef(
          platformVersion: () => '3.12.2 (stable) (Wed Jan 15 00:00:00 2025) on "macos_arm64"',
        ),
        equals('3.12.2'),
      );
    });

    test('takes the leading token of a beta Platform.version string', () {
      expect(
        resolveDartSdkRef(platformVersion: () => '3.13.0-282.2.beta (beta) (...) on "linux_x64"'),
        equals('3.13.0-282.2.beta'),
      );
    });

    test('takes the leading token of a dev Platform.version string', () {
      expect(
        resolveDartSdkRef(platformVersion: () => '3.14.0-41.0.dev (dev) (...) on "windows_x64"'),
        equals('3.14.0-41.0.dev'),
      );
    });
  });

  // ─── resolveFlutterSdkRef ───────────────────────────────────────────────────

  group('resolveFlutterSdkRef', () {
    late Directory flutterRoot;

    setUp(() {
      flutterRoot = Directory.systemTemp.createTempSync('dart_pubdev_mcp_flutter_root_test_');
    });

    tearDown(() {
      if (flutterRoot.existsSync()) flutterRoot.deleteSync(recursive: true);
    });

    void writeVersionFile(String content) {
      final cacheDir = Directory('${flutterRoot.path}/bin/cache')..createSync(recursive: true);
      File('${cacheDir.path}/flutter.version.json').writeAsStringSync(content);
    }

    test('reads frameworkVersion from FLUTTER_ROOT/bin/cache/flutter.version.json', () {
      writeVersionFile('{"frameworkVersion": "3.35.1", "channel": "stable"}');

      final ref = resolveFlutterSdkRef(environment: {'FLUTTER_ROOT': flutterRoot.path});

      expect(ref, equals('3.35.1'));
    });

    test('returns null when FLUTTER_ROOT is set but the version file is missing', () {
      final ref = resolveFlutterSdkRef(environment: {'FLUTTER_ROOT': flutterRoot.path});

      expect(ref, isNull);
    });

    test('returns null when the version file is not valid JSON', () {
      writeVersionFile('not json');

      final ref = resolveFlutterSdkRef(environment: {'FLUTTER_ROOT': flutterRoot.path});

      expect(ref, isNull);
    });

    test('returns null when the version file has no frameworkVersion field', () {
      writeVersionFile('{"channel": "stable"}');

      final ref = resolveFlutterSdkRef(environment: {'FLUTTER_ROOT': flutterRoot.path});

      expect(ref, isNull);
    });

    test('returns null when neither FLUTTER_ROOT nor a PATH match is present', () {
      final ref = resolveFlutterSdkRef(environment: const {'PATH': '/nonexistent/bin'});

      expect(ref, isNull);
    });

    test('an empty FLUTTER_ROOT value falls through to PATH lookup rather than a bare read', () {
      final ref = resolveFlutterSdkRef(
        environment: const {'FLUTTER_ROOT': '', 'PATH': '/nonexistent/bin'},
      );

      expect(ref, isNull);
    });
  });

  // ─── SdkClient.getSourceFiles ───────────────────────────────────────────────

  group('SdkClient.getSourceFiles', () {
    late TestStack stack;
    late MockHttpClient mockHttp;
    late Directory tempDir;
    late TarballDiskCache tarballCache;

    setUp(() {
      stack = TestStack();
      mockHttp = stack.http;
      tempDir = Directory.systemTemp.createTempSync('dart_pubdev_mcp_sdk_client_test_');
      tarballCache = TarballDiskCache(directoryPath: tempDir.path);
    });

    tearDown(() {
      stack.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    SdkClient buildClient() => SdkClient(
      httpClient: mockHttp,
      retryPolicy: instantRetryPolicy,
      tarballCache: tarballCache,
    );

    test('strips the GitHub wrapper directory and returns repo-relative paths', () async {
      stubSdkTarball(mockHttp, _files);

      final result = await buildClient().getSourceFiles(
        sdkId: 'dart',
        cacheName: 'dart_sdk',
        owner: 'dart-lang',
        repo: 'sdk',
        ref: '3.12.2',
      );

      expect(result, isA<PubDevSuccess<Map<String, String>>>());
      final files = (result as PubDevSuccess<Map<String, String>>).value;
      expect(files.keys, containsAll(_files.keys));
      expect(files['sdk/lib/core/list.dart'], equals('class List {}\n'));
    });

    test('builds a refs/tags/ URL for a tag-shaped ref', () async {
      stubSdkTarball(mockHttp, _files);

      await buildClient().getSourceFiles(
        sdkId: 'dart',
        cacheName: 'dart_sdk',
        owner: 'dart-lang',
        repo: 'sdk',
        ref: '3.12.2',
      );

      final captured = verify(() => mockHttp.send(captureAny())).captured;
      final request = captured.single as http.BaseRequest;
      expect(request.url.toString(), contains('/dart-lang/sdk/tar.gz/refs/tags/3.12.2'));
    });

    test('builds a bare-SHA URL for a commit-SHA-shaped ref', () async {
      const sha = 'abcdef1234567890abcdef1234567890abcdef12';
      stubSdkTarball(mockHttp, _files, ref: sha);

      await buildClient().getSourceFiles(
        sdkId: 'dart',
        cacheName: 'dart_sdk',
        owner: 'dart-lang',
        repo: 'sdk',
        ref: sha,
      );

      final captured = verify(() => mockHttp.send(captureAny())).captured;
      final request = captured.single as http.BaseRequest;
      expect(request.url.toString(), contains('/dart-lang/sdk/tar.gz/$sha'));
      expect(request.url.toString(), isNot(contains('refs/tags')));
    });

    test('does not issue a second download for a cached ref', () async {
      stubSdkTarball(mockHttp, _files);
      final client = buildClient();

      await client.getSourceFiles(
        sdkId: 'dart',
        cacheName: 'dart_sdk',
        owner: 'dart-lang',
        repo: 'sdk',
        ref: '3.12.2',
      );
      await client.getSourceFiles(
        sdkId: 'dart',
        cacheName: 'dart_sdk',
        owner: 'dart-lang',
        repo: 'sdk',
        ref: '3.12.2',
      );

      verify(() => mockHttp.send(any())).called(1);
    });

    test('returns SDK_VERSION_NOT_FOUND with details.sdk on a 404', () async {
      stubSdkTarball(mockHttp, _files, ref: '999.0.0', statusCode: 404);

      final result = await buildClient().getSourceFiles(
        sdkId: 'dart',
        cacheName: 'dart_sdk',
        owner: 'dart-lang',
        repo: 'sdk',
        ref: '999.0.0',
      );

      expect(result, isA<PubDevFailure<Map<String, String>>>());
      final error = (result as PubDevFailure<Map<String, String>>).error;
      expect(error.code, equals(DomainErrors.sdkVersionNotFound));
      expect(error.retryable, isFalse);
      expect(error.details, equals({'sdk': 'dart'}));
    });

    test('returns SDK_VERSION_NOT_FOUND for a malformed ref without any network call', () async {
      final result = await buildClient().getSourceFiles(
        sdkId: 'dart',
        cacheName: 'dart_sdk',
        owner: 'dart-lang',
        repo: 'sdk',
        ref: 'not/a/valid/ref',
      );

      expect(result, isA<PubDevFailure<Map<String, String>>>());
      expect(
        (result as PubDevFailure<Map<String, String>>).error.code,
        equals(DomainErrors.sdkVersionNotFound),
      );
      verifyNever(() => mockHttp.send(any()));
    });

    test('surfaces the existing retryable error shape unchanged on repeated 5xx', () async {
      stubSdkTarball(mockHttp, _files, statusCode: 503);

      final result = await buildClient().getSourceFiles(
        sdkId: 'dart',
        cacheName: 'dart_sdk',
        owner: 'dart-lang',
        repo: 'sdk',
        ref: '3.12.2',
      );

      expect(result, isA<PubDevFailure<Map<String, String>>>());
      final error = (result as PubDevFailure<Map<String, String>>).error;
      expect(error.code, equals(DomainErrors.serviceUnavailable));
      expect(error.retryable, isTrue);
    });
  });
}
