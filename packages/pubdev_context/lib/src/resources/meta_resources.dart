/// Resource handlers for the `pub://meta/` namespace.
///
/// Serves two resources via [ResourcesSupport.addResource]:
///   - `pub://meta/scoring`      — plain-text explanation of the pub.dev
///     160-point scoring system; content is embedded at compile time.
///   - `pub://meta/sdk-versions` — current stable Dart and Flutter SDK
///     versions fetched from Google Storage and returned as JSON.
///
/// Both resources are cached with a [kMetaResourcesTtl] (24-hour) TTL.
/// See issue #10.
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:http/http.dart' as http;

import '../cache/memory_cache.dart';

// ─── URIs ─────────────────────────────────────────────────────────────────────

/// URI for the pub.dev scoring explanation resource.
const _kScoringUri = 'pub://meta/scoring';

/// URI for the current stable SDK versions resource.
const _kSdkVersionsUri = 'pub://meta/sdk-versions';

// ─── Cache keys ───────────────────────────────────────────────────────────────

/// Cache key for the scoring body entry.
const _kScoringCacheKey = 'meta:scoring';

/// Cache key for the SDK-versions JSON entry.
const _kSdkVersionsCacheKey = 'meta:sdk-versions';

// ─── Endpoints ────────────────────────────────────────────────────────────────

/// Dart SDK stable VERSION endpoint (returns `{ version, date, revision }`).
const _kDartVersionUrl =
    'https://storage.googleapis.com/dart-archive/channels/stable/release/latest/VERSION';

/// Flutter SDK releases endpoint for Linux.
///
/// Top-level `current_release.stable` holds the hash of the latest stable
/// release; resolve it against `releases` to obtain the version string.
const _kFlutterReleasesUrl =
    'https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json';

/// Request timeout for each individual HTTP call made by the meta handler.
const _kRequestTimeout = Duration(seconds: 15);

// ─── Resource descriptors ─────────────────────────────────────────────────────

/// [Resource] descriptor for `pub://meta/scoring`.
final kScoringResource = Resource(
  uri: _kScoringUri,
  name: 'pub.dev scoring guide',
  description: 'Plain-text explanation of the pub.dev 160-point scoring system.',
  mimeType: 'text/plain',
);

/// [Resource] descriptor for `pub://meta/sdk-versions`.
final kSdkVersionsResource = Resource(
  uri: _kSdkVersionsUri,
  name: 'Stable SDK versions',
  description: 'Current stable Dart and Flutter SDK version strings as JSON.',
  mimeType: 'application/json',
);

// ─── Static content ───────────────────────────────────────────────────────────

/// Plain-text explanation of the pub.dev 160-point scoring system.
///
/// Embedded at compile time. No HTTP call or file I/O is performed on any
/// access to `pub://meta/scoring`; this constant is the sole source of the
/// resource body.
const kScoringContent = '''
pub.dev 160-Point Scoring System
=================================

pub.dev scores every package on a 0-160 scale using the pana analysis tool.
Scores are recomputed automatically on each new version publish.

CATEGORY 1 -- Follow Dart file conventions (0-20 points)
---------------------------------------------------------
Checks that the package follows the conventional structure expected of a
well-maintained Dart package.

Points are awarded for:
  * README.md is present and non-trivial.
  * CHANGELOG.md is present, non-trivial, and follows Keep-a-Changelog format.
  * A working example is provided (example/ directory or inline dartdoc examples).
  * pubspec.yaml contains a description between 60 and 180 characters.
  * pubspec.yaml contains a valid homepage or repository URL.
  * SDK and dependency version constraints are compatible and not overly tight.
  * No deprecated Dart API usage is detected by the analyzer.

CATEGORY 2 -- Provide documentation (0-10 points)
--------------------------------------------------
Checks that public symbols carry doc comments (///).

Points scale with the percentage of public API members that have a doc comment.
Full marks require >= 80% coverage. The package main library must also carry
a library-level doc comment.

CATEGORY 3 -- Platform support (0-20 points)
---------------------------------------------
Rewards packages that run on many platforms and runtimes.

Detected platforms: Android, iOS, macOS, Linux, Windows, Web.
Points increase with the number of supported platforms. Annotate the supported
platforms in pubspec.yaml under the flutter.plugin.platforms section (Flutter
packages) or declare sdk: dart with no platform-exclusive imports (Dart-only).

CATEGORY 4 -- Pass static analysis (0-50 points)
-------------------------------------------------
The most heavily weighted category. Points are deducted for any issue reported
by dart analyze, including:

  * Analyzer errors or warnings.
  * Lints triggered under the recommended or very_good_analysis rule sets.
  * Code that has not been formatted with dart format.
  * Use of dynamic or missing return-type annotations.

Zero errors and zero warnings with formatted code yield the full 50 points.
Even a single analyzer warning can reduce the score significantly.

CATEGORY 5 -- Support up-to-date dependencies (0-60 points)
------------------------------------------------------------
Rewards packages whose dependencies allow the latest published versions.

pana checks each direct dependency listed in pubspec.yaml:
  * All constraints include the latest version     -> full points.
  * One or more constraints exclude latest version -> proportional deduction.
  * Any dependency has been discontinued/retracted -> heavy penalty.

Best practices:
  * Use caret syntax (^x.y.z) to allow compatible upgrades.
  * Avoid pinned exact versions (== x.y.z) -- they lose points as dependencies
    advance.
  * Run dart pub upgrade and republish promptly after dependency releases.

SUMMARY
-------
Category                          Max pts  Key action
Follow Dart file conventions           20  README, CHANGELOG, example, pubspec
Provide documentation                  10  /// on >= 80% of public API members
Platform support                       20  Declare all supported platforms
Pass static analysis                   50  Zero analyzer issues; dart format clean
Support up-to-date dependencies        60  Open upper bounds; update promptly
TOTAL                                 160
''';

// ─── MetaResourcesHandler ─────────────────────────────────────────────────────

/// Resource handler for the `pub://meta/` namespace.
///
/// Register the two meta resources on a [ResourcesSupport] server by passing
/// [handleScoring] and [handleSdkVersions] as the `impl` argument to
/// [ResourcesSupport.addResource]:
///
/// ```dart
/// final meta = MetaResourcesHandler(httpClient: client, cache: cache, log: log);
/// addResource(kScoringResource, meta.handleScoring);
/// addResource(kSdkVersionsResource, meta.handleSdkVersions);
/// ```
///
/// [handleScoring] never issues an HTTP call -- the body is the compile-time
/// constant [kScoringContent]. [handleSdkVersions] fetches both Google Storage
/// endpoints concurrently on a cache miss and caches the resulting JSON for
/// [kMetaResourcesTtl] (24 hours).
final class MetaResourcesHandler {
  /// Creates a [MetaResourcesHandler].
  ///
  /// [httpClient] is used exclusively by [handleSdkVersions] to fetch the two
  /// Google Storage endpoints; [handleScoring] never calls it. [cache] is the
  /// shared TTL store for both resources. [log] receives log events at the
  /// appropriate [LoggingLevel].
  const MetaResourcesHandler({
    required http.Client httpClient,
    required ResponseCache<String> cache,
    required void Function(LoggingLevel, Object) log,
  }) : _http = httpClient,
       _cache = cache,
       _log = log;

  final http.Client _http;
  final ResponseCache<String> _cache;
  final void Function(LoggingLevel, Object) _log;

  // ── Handlers ──────────────────────────────────────────────────────────────

  /// Handles a [ReadResourceRequest] for `pub://meta/scoring`.
  ///
  /// Returns the compile-time constant [kScoringContent] with MIME type
  /// `text/plain`. No HTTP call is ever made. The body is stored in [_cache]
  /// under key `meta:scoring` on first access so that the cache-hit branch is
  /// exercised on subsequent requests within the [kMetaResourcesTtl] window.
  Future<ReadResourceResult> handleScoring(ReadResourceRequest request) async {
    final cached = _cache.get(_kScoringCacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'meta:scoring cache hit');
      return _textResult(request.uri, await cached, 'text/plain');
    }
    _log(LoggingLevel.debug, 'meta:scoring cache miss');
    _cache.set(_kScoringCacheKey, Future.value(kScoringContent), kMetaResourcesTtl);
    return _textResult(request.uri, kScoringContent, 'text/plain');
  }

  /// Handles a [ReadResourceRequest] for `pub://meta/sdk-versions`.
  ///
  /// On a cache miss, fetches the current stable Dart and Flutter SDK versions
  /// from [_kDartVersionUrl] and [_kFlutterReleasesUrl] concurrently, then
  /// returns a JSON object `{ "dart": "<version>", "flutter": "<version>" }`
  /// with MIME type `application/json`. The result is cached in [_cache] under
  /// key `meta:sdk-versions` with a [kMetaResourcesTtl] TTL.
  ///
  /// Throws [Exception] if either endpoint returns a non-200 status, the
  /// response cannot be parsed, or the stable Flutter release hash is absent
  /// from the releases list.
  Future<ReadResourceResult> handleSdkVersions(ReadResourceRequest request) async {
    final cached = _cache.get(_kSdkVersionsCacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'meta:sdk-versions cache hit');
      return _textResult(request.uri, await cached, 'application/json');
    }
    _log(LoggingLevel.debug, 'meta:sdk-versions cache miss');
    _log(LoggingLevel.info, 'meta:sdk-versions HTTP fetch');
    final json = await _fetchSdkVersions();
    _cache.set(_kSdkVersionsCacheKey, Future.value(json), kMetaResourcesTtl);
    return _textResult(request.uri, json, 'application/json');
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  /// Fetches stable Dart and Flutter SDK versions from Google Storage.
  ///
  /// Issues both GET requests concurrently and waits for both to complete.
  /// Parses `version` from the Dart VERSION JSON and resolves
  /// `current_release.stable` against the Flutter releases array to obtain the
  /// Flutter version string. Returns a JSON-encoded `{ dart, flutter }` object.
  Future<String> _fetchSdkVersions() async {
    final (dartResponse, flutterResponse) = await (
      _http.get(Uri.parse(_kDartVersionUrl)).timeout(_kRequestTimeout),
      _http.get(Uri.parse(_kFlutterReleasesUrl)).timeout(_kRequestTimeout),
    ).wait;

    if (dartResponse.statusCode != 200) {
      throw Exception(
        'Dart VERSION endpoint returned HTTP ${dartResponse.statusCode}.',
      );
    }
    if (flutterResponse.statusCode != 200) {
      throw Exception(
        'Flutter releases endpoint returned HTTP ${flutterResponse.statusCode}.',
      );
    }

    final dartData = jsonDecode(dartResponse.body) as Map<String, Object?>;
    final dartVersion = dartData['version'] as String;

    final flutterData = jsonDecode(flutterResponse.body) as Map<String, Object?>;
    final currentRelease = flutterData['current_release'] as Map<String, Object?>;
    final stableHash = currentRelease['stable'] as String;
    final releases = (flutterData['releases'] as List<Object?>).cast<Map<String, Object?>>();
    final stableRelease = releases.firstWhere(
      (r) => r['hash'] == stableHash,
      orElse: () => throw Exception(
        'Flutter stable release with hash $stableHash not found in releases list.',
      ),
    );
    final flutterVersion = stableRelease['version'] as String;

    return jsonEncode({'dart': dartVersion, 'flutter': flutterVersion});
  }

  static ReadResourceResult _textResult(String uri, String text, String mimeType) =>
      ReadResourceResult(
        contents: [TextResourceContents(uri: uri, text: text, mimeType: mimeType)],
      );
}
