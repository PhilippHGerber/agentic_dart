/// HTTP gateway to version-pinned SDK source tarballs on `codeload.github.com`.
///
/// Mirrors [PubDevClient]'s tarball acquisition path (download, decompress,
/// extract, disk-cache) for source pub.dev never hosts: the Dart SDK
/// (`dart-lang/sdk`) and the Flutter SDK/framework (`flutter/flutter`), per
/// ADR 0006. Raw HTTP, retry, and error mapping reuse
/// [RetryPolicy]/[HttpStatusException] verbatim rather than reimplementing
/// them.
library;

import 'dart:async' show TimeoutException;
import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

import '../cache/tarball_disk_cache.dart';
import 'domain_error.dart';
import 'pub_client.dart' show HttpStatusException, PubDevClient, RetryPolicy;

const _kCodeloadBaseUrl = 'https://codeload.github.com';

/// Resolves the default Dart SDK ref this process is running under.
///
/// `Platform.version` (or [platformVersion] when supplied, for testing) is
/// formatted like `"3.12.2 (stable) (Wed Jan 15 00:00:00 2025) on ..."`; only
/// the leading version token is used, taken verbatim as the `dart-lang/sdk`
/// tag — no channel branching is needed (verified live against the stable,
/// beta, and dev channels; see ADR 0006).
String resolveDartSdkRef({String Function()? platformVersion}) =>
    (platformVersion ?? () => Platform.version)().split(' ').first;

/// Resolves the default Flutter SDK ref (its `frameworkVersion`) from a local
/// Flutter install, located via `FLUTTER_ROOT` or a `flutter`/`flutter.bat`
/// executable on `PATH`.
///
/// Reads `<flutterRoot>/bin/cache/flutter.version.json`'s `frameworkVersion`
/// field — the same file `flutter --version` itself populates. Returns `null`
/// when no install can be located, or a located install's version file is
/// missing or unparseable; callers surface [DomainErrors.sdkNotDetected] in
/// that case. Never spawns a subprocess (e.g. `flutter --version`) to recover
/// a version — see ADR 0006.
///
/// [environment] overrides [Platform.environment] for testing — in
/// particular to point `FLUTTER_ROOT` at a fixture directory. Production
/// callers omit it.
String? resolveFlutterSdkRef({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final root = _locateFlutterRoot(env);
  if (root == null) return null;

  final versionFile = File('$root/bin/cache/flutter.version.json');
  if (!versionFile.existsSync()) return null;

  try {
    final decoded = jsonDecode(versionFile.readAsStringSync());
    if (decoded is! Map<String, Object?>) return null;
    final frameworkVersion = decoded['frameworkVersion'];
    return frameworkVersion is String && frameworkVersion.isNotEmpty ? frameworkVersion : null;
  } on FormatException {
    return null;
  }
}

/// Resolves a Flutter SDK root directory from [env]'s `FLUTTER_ROOT`, or by
/// locating a `flutter`/`flutter.bat` executable on `PATH` and walking up
/// from `<root>/bin/<executable>` to `<root>`. Returns `null` when neither
/// resolves to a real path.
///
/// PATH entries that are symlinks are not resolved to their target — a
/// `flutter` shim symlinked in from outside its SDK checkout is not detected
/// this way. `FLUTTER_ROOT` (or an explicit `version` override) always works
/// regardless.
String? _locateFlutterRoot(Map<String, String> env) {
  final flutterRoot = env['FLUTTER_ROOT'];
  if (flutterRoot != null && flutterRoot.isNotEmpty) return flutterRoot;

  final pathEnv = env['PATH'];
  if (pathEnv == null || pathEnv.isEmpty) return null;

  final separator = Platform.isWindows ? ';' : ':';
  final executableName = Platform.isWindows ? 'flutter.bat' : 'flutter';
  for (final dir in pathEnv.split(separator)) {
    if (dir.isEmpty) continue;
    final candidate = '$dir${Platform.pathSeparator}$executableName';
    if (!File(candidate).existsSync()) continue;
    final binDir = _parentDirectory(candidate);
    final root = binDir == null ? null : _parentDirectory(binDir);
    if (root != null) return root;
  }
  return null;
}

/// Returns the parent directory of [path] (accepting both `/` and `\`
/// separators), or `null` when [path] has no parent segment.
String? _parentDirectory(String path) {
  final normalized = path.replaceAll(r'\', '/');
  final trimmed = normalized.endsWith('/')
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
  final slash = trimmed.lastIndexOf('/');
  if (slash <= 0) return null;
  return trimmed.substring(0, slash);
}

/// HTTP client for version-pinned SDK source tarballs on `codeload.github.com`.
///
/// One instance is shared by every SDK-source tool handler via
/// `CacheRegistry`, the same way [PubDevClient] is shared for pub.dev
/// packages.
final class SdkClient {
  /// Creates an [SdkClient].
  ///
  /// Supply [httpClient] and [retryPolicy] to override the defaults — useful
  /// for testing without live network calls. [tarballCache] persists
  /// downloaded tarballs to disk; pass the same [TarballDiskCache] instance
  /// [PubDevClient] uses — the fixed `dart_sdk`/`flutter_sdk` cache names
  /// (ADR 0006) pass the same charset validation as a pub.dev package name,
  /// so the two acquisition paths can safely share one cache directory.
  SdkClient({
    http.Client? httpClient,
    RetryPolicy? retryPolicy,
    Duration requestTimeout = const Duration(seconds: 10),
    TarballDiskCache? tarballCache,
  }) : _http = httpClient ?? http.Client(),
       _retry = retryPolicy ?? RetryPolicy(),
       _timeout = requestTimeout,
       _tarballCache = tarballCache;

  final http.Client _http;
  final RetryPolicy _retry;
  final Duration _timeout;
  final TarballDiskCache? _tarballCache;

  static const int _kMaxTarballBytes = 50 * 1024 * 1024;

  /// See [PubDevClient]'s identically-purposed constant for the rationale —
  /// converts the per-chunk idle [_timeout] into a hard wall-clock cap for
  /// the entire streaming download.
  static const int _kDownloadTimeoutFactor = 10;

  // Mirrors the validation in TarballDiskCache._fileFor so that a malformed
  // cache name or ref is rejected with a structured DomainError before any
  // I/O is attempted.
  static final _kSafeName = RegExp(r'^[a-zA-Z0-9_]+$');
  static final _kSafeRef = RegExp(r'^[0-9a-zA-Z.+_-]+$');

  // A resolved ref that looks like a full or short commit SHA (hex digits
  // only) resolves to codeload's bare-SHA path rather than its tag path.
  // Every real Dart/Flutter SDK tag contains at least one '.', so this never
  // misclassifies a tag as a SHA.
  static final _kCommitShaPattern = RegExp(r'^[0-9a-fA-F]{7,40}$');

  /// Closes the underlying HTTP client and releases its resources.
  void close() => _http.close();

  /// Downloads and extracts the source tree for [owner]/[repo] at [ref].
  ///
  /// Returns a `Map<String, String>` from file path (relative to the repo
  /// root) to file content — the GitHub tarball's wrapping `{repo}-{ref}/`
  /// directory is stripped from every entry, so e.g. `dart-lang/sdk`'s
  /// `sdk/lib/core/list.dart` is returned as `sdk/lib/core/list.dart` rather
  /// than `sdk-3.12.2/sdk/lib/core/list.dart`.
  ///
  /// [cacheName] is the fixed per-SDK cache-key name (`dart_sdk` /
  /// `flutter_sdk`); a hit against [_tarballCache] under `(cacheName, ref)`
  /// skips the download entirely. [sdkId] (`'dart'` / `'flutter'`) is used
  /// only to build the [DomainErrors.sdkVersionNotFound] error's `details`.
  ///
  /// Returns [DomainErrors.sdkVersionNotFound] when [cacheName] or [ref]
  /// contain characters no real cache key or GitHub ref can (an unparseable
  /// or malformed version can never resolve to a real SDK release), or when
  /// [ref] matches no tag or commit on `codeload.github.com` (surfaced as an
  /// HTTP 404). Other transient failures reuse [RetryPolicy]'s existing
  /// retryable/non-retryable error shape unchanged.
  Future<PubDevResult<Map<String, String>>> getSourceFiles({
    required String sdkId,
    required String cacheName,
    required String owner,
    required String repo,
    required String ref,
  }) async {
    if (!_kSafeName.hasMatch(cacheName) || !_kSafeRef.hasMatch(ref)) {
      return PubDevFailure(_sdkVersionNotFound(sdkId, ref));
    }

    final cachedBytes = await _tarballCache?.read(cacheName, ref);
    if (cachedBytes != null) {
      return _extractSourceFiles(cachedBytes);
    }

    final refPath = _kCommitShaPattern.hasMatch(ref) ? ref : 'refs/tags/$ref';
    final url = '$_kCodeloadBaseUrl/$owner/$repo/tar.gz/$refPath';

    final result = await _retry.execute(
      (attempt) => _downloadBytesWithLimit(url, maxBytes: _kMaxTarballBytes),
    );
    if (result case PubDevFailure<List<int>>(:final error)) {
      return PubDevFailure(_remapNotFound(error, sdkId, ref));
    }

    final bytes = (result as PubDevSuccess<List<int>>).value;
    final extracted = _extractSourceFiles(bytes);
    if (extracted case PubDevFailure<Map<String, String>>()) {
      return extracted;
    }

    // Persist only validated tarballs so malformed downloads cannot poison
    // the cache for future requests.
    await _tarballCache?.write(cacheName, ref, bytes);

    return extracted;
  }

  /// Remaps a 404-derived [DomainErrors.packageNotFound] failure (the generic
  /// code [RetryPolicy] produces for any HTTP 404) into
  /// [DomainErrors.sdkVersionNotFound]; every other error code passes through
  /// unchanged, preserving [RetryPolicy]'s existing retryable/non-retryable
  /// shape for transient failures.
  DomainError _remapNotFound(DomainError error, String sdkId, String ref) {
    if (error.code != DomainErrors.packageNotFound) return error;
    return _sdkVersionNotFound(sdkId, ref);
  }

  static DomainError _sdkVersionNotFound(String sdkId, String ref) => DomainError(
    code: DomainErrors.sdkVersionNotFound,
    message: 'No $sdkId SDK release matches version "$ref".',
    suggestion:
        'Verify the version string is a real tag or commit SHA, '
        'or omit it to auto-detect the running SDK version.',
    details: {'sdk': sdkId},
  );

  static PubDevResult<Map<String, String>> _extractSourceFiles(List<int> bytes) {
    try {
      final decompressed = const GZipDecoder().decodeBytes(bytes);
      final archive = TarDecoder().decodeBytes(decompressed);
      final files = <String, String>{};
      for (final entry in archive) {
        if (!entry.isFile) continue;
        final stripped = _stripWrapperDir(entry.name);
        if (stripped == null) continue;
        final content = utf8.decode(entry.content, allowMalformed: true);
        files[stripped] = content;
      }
      return PubDevSuccess(files);
    } on Object {
      return const PubDevFailure(
        DomainError(
          code: DomainErrors.unexpectedResponse,
          message: 'Failed to decode the SDK source tarball.',
          suggestion: 'Try again later or check the GitHub status page.',
        ),
      );
    }
  }

  /// Strips a GitHub tarball entry's wrapping top-level directory
  /// (`{repo}-{ref}/rest/of/path` → `rest/of/path`). Returns `null` for the
  /// wrapper directory entry itself, which has no remaining path segment.
  static String? _stripWrapperDir(String path) {
    final slash = path.indexOf('/');
    if (slash < 0 || slash == path.length - 1) return null;
    return path.substring(slash + 1);
  }

  Future<List<int>> _downloadBytesWithLimit(String url, {required int maxBytes}) async {
    final uri = Uri.parse(url);
    final response = await _http.send(http.Request('GET', uri)).timeout(_timeout);

    if (response.statusCode != 200) {
      throw HttpStatusException(response.statusCode);
    }

    final bytes = BytesBuilder(copy: false);
    var receivedBytes = 0;
    final downloadDeadline = DateTime.now().add(_timeout * _kDownloadTimeoutFactor);

    // _timeout acts as a per-chunk idle deadline (stream.timeout resets on
    // every event). The deadline check below enforces a hard wall-clock cap
    // on the entire download so a slow-drip server cannot hold the download
    // open indefinitely. Throwing inside `await for` triggers
    // subscription.cancel(), which properly closes the stream.
    await for (final chunk in response.stream.timeout(_timeout)) {
      receivedBytes += chunk.length;
      if (receivedBytes > maxBytes) {
        throw const HttpStatusException(413);
      }
      if (DateTime.now().isAfter(downloadDeadline)) {
        throw TimeoutException(
          'Download exceeded total time limit',
          _timeout * _kDownloadTimeoutFactor,
        );
      }
      bytes.add(chunk);
    }

    return bytes.takeBytes();
  }
}
