/// HTTP gateway to the pub.dev public REST API.
///
/// All network concerns — URL construction, response parsing, error mapping,
/// and retry logic — are encapsulated here. Raw HTTP and JSON never escape
/// this module; every public method returns a typed [PubDevResult].
library;

import 'dart:async' show Completer, TimeoutException, Zone;
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

import '../cache/memory_cache.dart';
import '../cache/tarball_disk_cache.dart';
import '../trace/wire_trace.dart';
import 'domain_error.dart';
import 'html_to_markdown.dart';
import 'models.dart';

// ─── RetryPolicy ─────────────────────────────────────────────────────────────

/// Executes an HTTP operation with exponential backoff.
///
/// Retries on HTTP 429, 500, 502, 503, and 504. Stops immediately on 404 or
/// any other 4xx. After [maxAttempts] exhausted retries, returns a structured
/// [DomainError] rather than throwing.
///
/// Default timing: up to 3 attempts with delays of 500 ms, 1 000 ms, 2 000 ms.
final class RetryPolicy {
  /// Creates a [RetryPolicy] with optional configuration overrides.
  ///
  /// Supply a custom [delay] to control timing in tests without real waits.
  RetryPolicy({
    this.maxAttempts = 3,
    this.initialDelay = const Duration(milliseconds: 500),
    this.multiplier = 2.0,
    Future<void> Function(Duration)? delay,
  }) : _delay = delay ?? Future.delayed;

  /// Maximum number of attempts, including the first one.
  final int maxAttempts;

  /// Delay before the second attempt.
  final Duration initialDelay;

  /// Factor applied to the delay after each failure.
  final double multiplier;

  final Future<void> Function(Duration) _delay;

  static const _retryStatusCodes = {429, 500, 502, 503, 504};
  static const _timeoutSentinel = -1;

  /// Executes [operation], retrying on transient HTTP failures and timeouts.
  ///
  /// [operation] receives the zero-based attempt number, so a caller can annotate
  /// a retried request (attempt `> 0`) in diagnostics. Returns [PubDevSuccess] on
  /// the first successful response, or [PubDevFailure] once retries are exhausted
  /// or a non-retryable error is encountered.
  ///
  /// When a retryable failure will be followed by another attempt, [onRetry] is
  /// invoked with the failure, the one-based retry number, and the backoff delay
  /// about to be waited. When a retryable failure is instead the last attempt
  /// (retries exhausted), [onGiveUp] is invoked with that final failure. Together
  /// they let the caller log every retryable response exactly once — as a retry
  /// line while more attempts remain, or as a plain response line on give-up —
  /// without this policy depending on any diagnostics subsystem. Neither is
  /// called for a non-retryable failure (the caller has already observed that
  /// response) nor for a timeout (which carries no status or path to render).
  Future<PubDevResult<T>> execute<T>(
    Future<T> Function(int attempt) operation, {
    void Function(HttpStatusException failure, int retryNumber, Duration backoff)? onRetry,
    void Function(HttpStatusException failure)? onGiveUp,
  }) async {
    final failures = <int>[];
    var delay = initialDelay;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0) {
        await _delay(delay);
        delay = Duration(
          milliseconds: (delay.inMilliseconds * multiplier).round(),
        );
      }

      try {
        return PubDevSuccess(await operation(attempt));
      } on TimeoutException {
        failures.add(_timeoutSentinel);
      } on HttpStatusException catch (e) {
        final retryable = _retryStatusCodes.contains(e.statusCode);
        final clientError = e.statusCode >= 400 && e.statusCode < 500 && e.statusCode != 429;
        if (!retryable || clientError) {
          return PubDevFailure(_errorForStatus(e.statusCode));
        }
        failures.add(e.statusCode);
        // Another attempt follows only while attempts remain. `delay` still holds
        // the backoff about to be waited at the top of the next iteration (it is
        // advanced only after that wait), so it is the correct value here.
        if (attempt + 1 < maxAttempts) {
          onRetry?.call(e, attempt + 1, delay);
        } else {
          onGiveUp?.call(e);
        }
      }
    }

    return PubDevFailure(_exhaustedError(failures));
  }

  /// Whether [statusCode] is one this policy retries — a transient 429 or 5xx.
  ///
  /// Exposed so a caller that logs responses can defer a retryable failure's
  /// line to [execute]'s `onRetry`/`onGiveUp` hooks and avoid double-logging it.
  static bool isRetryableStatus(int statusCode) => _retryStatusCodes.contains(statusCode);

  static DomainError _errorForStatus(int statusCode) => switch (statusCode) {
    404 => const DomainError(
      code: DomainErrors.packageNotFound,
      message: 'Package not found on pub.dev.',
      suggestion: 'Verify the package name and try again.',
    ),
    413 => const DomainError(
      code: DomainErrors.packageTooLarge,
      message: 'Package tarball exceeds the maximum allowed download size.',
      suggestion: 'Try a smaller package version or inspect metadata without downloading sources.',
    ),
    429 => const DomainError(
      code: DomainErrors.rateLimited,
      message: 'pub.dev rate-limited this request.',
      suggestion: 'Wait a moment and retry.',
    ),
    _ when statusCode >= 500 => const DomainError(
      code: DomainErrors.serviceUnavailable,
      message: 'pub.dev is temporarily unavailable.',
      suggestion: 'Try again in a few seconds.',
    ),
    _ => DomainError(
      code: DomainErrors.unexpectedResponse,
      message: 'pub.dev returned an unexpected HTTP $statusCode response.',
      suggestion: 'Check the pub.dev status page.',
    ),
  };

  static DomainError _exhaustedError(List<int> failures) {
    if (failures.every((c) => c == _timeoutSentinel)) {
      return const DomainError(
        code: DomainErrors.requestTimeout,
        message: 'pub.dev did not respond within the allotted time.',
        suggestion: 'Check your network connection and try again.',
      );
    }
    if (failures.every((c) => c == 429)) {
      return const DomainError(
        code: DomainErrors.rateLimited,
        message: 'pub.dev rate-limited all retry attempts.',
        suggestion: 'Wait a moment and retry.',
      );
    }
    if (failures.every((c) => c >= 500)) {
      return const DomainError(
        code: DomainErrors.serviceUnavailable,
        message: 'pub.dev was unavailable across all retry attempts.',
        suggestion: 'Check the pub.dev status page and try again later.',
      );
    }
    return _errorForStatus(failures.last);
  }
}

// ─── HTTP status exception ────────────────────────────────────────────────────

/// Thrown inside [RetryPolicy.execute] operations to signal an HTTP error code.
///
/// [RetryPolicy] inspects [statusCode] to decide whether to retry or fail.
/// This is an internal transport type — it never crosses module boundaries.
///
/// [path] and [latency] carry the failing request's endpoint and observed
/// round-trip time so a retry can be logged to the Wire Trace. They are optional
/// because some failures (a hard byte-limit rejection) are constructed without a
/// live response to measure.
class HttpStatusException implements Exception {
  /// Creates an exception for the given HTTP [statusCode].
  const HttpStatusException(this.statusCode, {this.path, this.latency});

  /// The HTTP status code that caused the failure.
  final int statusCode;

  /// The request path (no scheme or host) that produced this status, if known.
  final String? path;

  /// The observed round-trip latency of the failing request, if measured.
  final Duration? latency;
}

// ─── Semaphore ────────────────────────────────────────────────────────────────

/// Counter-based async lock that caps how many operations run concurrently.
final class _Semaphore {
  _Semaphore(this.maxConcurrency) : _count = maxConcurrency;

  final int maxConcurrency;
  int _count;
  final _waiters = <Completer<void>>[];

  Future<void> acquire() async {
    if (_count > 0) {
      _count--;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _count++;
    }
  }
}

// ─── PubDevClient ─────────────────────────────────────────────────────────────

const _kBaseUrl = 'https://pub.dev';
const _kAccept = 'application/vnd.pub.v2+json';

const _unexpectedResponse = DomainError(
  code: DomainErrors.unexpectedResponse,
  message: 'pub.dev returned an unexpected response format.',
  suggestion: 'Try again later or check the pub.dev status page.',
);

/// HTTP client for the pub.dev public REST API.
///
/// Every method maps to one or more pub.dev endpoints and returns a typed
/// [PubDevResult]. No raw HTTP or JSON escapes this class. All requests include
/// the `Accept: application/vnd.pub.v2+json` header. Retry behaviour is
/// delegated to the [RetryPolicy] supplied at construction time.
///
/// This client is not a purely stateless-per-call gateway: it owns two caches,
/// each consulted transparently before the corresponding request reaches the
/// network.
///
/// - The **Tarball Disk Cache** ([TarballDiskCache]) persists downloaded package
///   tarballs to disk and is checked inside [getPackageSourceFiles].
/// - The **Package Info Cache** (an in-memory, TTL-bound, single-flight
///   [ResponseCache]) memoises `GET /api/packages/{name}` responses so that
///   endpoint is fetched at most once per package per [kPackageMetadataTtl]
///   window. It is shared by [resolveLatestStable], [getPackage], [listVersions],
///   and search enrichment, all of which route through one private fetch helper.
///
/// Both caches are optional constructor dependencies; when omitted, the client
/// falls back to fetching fresh on every call.
final class PubDevClient {
  /// Creates a [PubDevClient].
  ///
  /// Supply [httpClient] and [retryPolicy] to override the defaults — useful
  /// for testing without live network calls. [requestTimeout] sets the deadline
  /// for each individual HTTP call; the [RetryPolicy] may issue multiple calls
  /// up to [RetryPolicy.maxAttempts] before returning a failure.
  ///
  /// [tarballCache] and [packageInfoCache] are the two caches described in the
  /// class doc above; when supplied they are consulted transparently inside the
  /// relevant methods. Both are constructed once in server wiring and passed the
  /// same [trace] so their `⚡ cache hit` lines appear automatically.
  ///
  /// When an enabled [trace] is supplied, every outbound pub.dev request and its
  /// response are logged to the Wire Trace, correlated — via the ambient [Zone]
  /// id read at call time — to the LLM request that triggered them. When [trace]
  /// is null nothing is built or logged; this long-lived client is shared across
  /// requests, so it reads the Correlation Id from [Zone.current] on each call
  /// rather than holding one.
  PubDevClient({
    http.Client? httpClient,
    RetryPolicy? retryPolicy,
    Duration requestTimeout = const Duration(seconds: 10),
    int maxConcurrency = 5,
    TarballDiskCache? tarballCache,
    ResponseCache<Map<String, Object?>>? packageInfoCache,
    WireTrace? trace,
  }) : _http = httpClient ?? http.Client(),
       _retry = retryPolicy ?? RetryPolicy(),
       _timeout = requestTimeout,
       _semaphore = _Semaphore(maxConcurrency),
       _tarballCache = tarballCache,
       _packageInfoCache = packageInfoCache,
       _trace = trace;

  final http.Client _http;
  final RetryPolicy _retry;
  final Duration _timeout;
  final _Semaphore _semaphore;
  final TarballDiskCache? _tarballCache;
  final ResponseCache<Map<String, Object?>>? _packageInfoCache;
  final WireTrace? _trace;

  static const int _kMaxTarballBytes = 50 * 1024 * 1024;

  // Mirrors the validation in TarballDiskCache._fileFor so that invalid inputs
  // are rejected with a structured DomainError before any I/O is attempted.
  static final _kSafePackageName = RegExp(r'^[a-zA-Z0-9_]+$');
  static final _kSafeVersionString = RegExp(r'^[0-9a-zA-Z.+_-]+$');

  /// Multiplier applied to [_timeout] to derive the total download deadline.
  ///
  /// [_timeout] controls the per-chunk idle deadline (no data for _timeout →
  /// abort). This factor converts it into a hard wall-clock cap for the entire
  /// streaming download. At the default 10 s timeout a factor of 10 yields a
  /// 100-second total deadline — enough for 50 MB at ~500 KB/s while still
  /// bounding runaway slow-drip connections.
  static const int _kDownloadTimeoutFactor = 10;

  /// Closes the underlying HTTP client and releases its resources.
  ///
  /// Call this when the [PubDevClient] is no longer needed. If no custom
  /// `httpClient` was supplied at construction time, the internal client's
  /// lifetime is owned by this object and must be closed explicitly.
  void close() => _http.close();

  // ── Endpoints ──────────────────────────────────────────────────────────────

  /// Returns full details for [name] from `GET /api/packages/{name}`.
  ///
  /// Combines the package-info and score endpoints internally, then fetches a
  /// README excerpt from the documentation page.
  Future<PubDevResult<PackageDetail>> getPackage(String name) async {
    final (infoResult, scoreResult) = await (
      _fetchPackageInfo(name),
      _fetchJson('$_kBaseUrl/api/packages/$name/score'),
    ).wait;

    if (infoResult case PubDevFailure<Map<String, Object?>>(:final error)) {
      return PubDevFailure(error);
    }
    if (scoreResult case PubDevFailure<Map<String, Object?>>(:final error)) {
      return PubDevFailure(error);
    }

    final infoData = (infoResult as PubDevSuccess<Map<String, Object?>>).value;
    final scoreData = (scoreResult as PubDevSuccess<Map<String, Object?>>).value;

    String? readmeExcerpt;
    try {
      String convert(String html) =>
          HtmlToMarkdown.convert(html, isolateClass: 'desc markdown', maxChars: 500);
      final html = await _getRaw(
        '$_kBaseUrl/documentation/$name/latest/',
        htmlPreview: convert,
      );
      readmeExcerpt = convert(html);
    } on HttpStatusException {
      // README is optional — unavailable docs are not a fatal error.
    }

    return PubDevSuccess(
      PackageDetail.fromPackageAndScore(
        infoData,
        scoreData,
        readmeExcerpt: readmeExcerpt,
      ),
    );
  }

  /// Returns details for a specific [version] of [name].
  ///
  /// Calls `GET /api/packages/{name}/versions/{version}` and
  /// `GET /api/packages/{name}/score` in parallel, then builds a
  /// [PackageDetail] from the combined data.
  Future<PubDevResult<PackageDetail>> getPackageVersion(
    String name,
    String version,
  ) async {
    final (versionResult, scoreResult) = await (
      _fetchJson('$_kBaseUrl/api/packages/$name/versions/$version'),
      _fetchJson('$_kBaseUrl/api/packages/$name/score'),
    ).wait;

    if (versionResult case PubDevFailure<Map<String, Object?>>(:final error)) {
      return PubDevFailure(error);
    }
    if (scoreResult case PubDevFailure<Map<String, Object?>>(:final error)) {
      return PubDevFailure(error);
    }

    final versionData = (versionResult as PubDevSuccess<Map<String, Object?>>).value;
    final scoreData = (scoreResult as PubDevSuccess<Map<String, Object?>>).value;

    final packageInfo = <String, Object?>{
      'name': name,
      'latest': versionData,
      'versions': [versionData],
    };
    return PubDevSuccess(
      PackageDetail.fromPackageAndScore(packageInfo, scoreData),
    );
  }

  /// Searches pub.dev and returns a list of enriched [PackageSummary] records.
  ///
  /// Calls `GET /api/search?q=...` then fetches package-info and score for
  /// each result in parallel. Failed individual lookups are silently skipped.
  /// Sort values: `relevance` (default), `likes`, `pubPoints`, `updated`.
  Future<PubDevResult<List<PackageSummary>>> search(
    String query, {
    String sort = 'relevance',
    String? sdk,
    String? platform,
    int page = 1,
    int limit = 10,
  }) async {
    final params = <String, String>{'q': query};
    final mappedSort = _mapSort(sort);
    if (mappedSort != null) params['sort'] = mappedSort;
    if (sdk != null) params['sdk'] = sdk;
    if (platform != null) params['platform'] = platform;
    if (page > 1) params['page'] = '$page';

    final url = Uri.parse('$_kBaseUrl/api/search').replace(queryParameters: params).toString();

    final searchResult = await _fetchJson(url);
    if (searchResult case PubDevFailure<Map<String, Object?>>(:final error)) {
      return PubDevFailure(error);
    }

    final searchData = (searchResult as PubDevSuccess<Map<String, Object?>>).value;
    final names = ((searchData['packages'] as List<Object?>?) ?? const [])
        .whereType<Map<String, Object?>>()
        .map((p) => p['package'] as String?)
        .whereType<String>()
        .take(limit)
        .toList();

    final summaries = await Future.wait(names.map(_fetchSummary));
    return PubDevSuccess(summaries.whereType<PackageSummary>().toList());
  }

  /// Returns the score for [name] from `GET /api/packages/{name}/score`.
  Future<PubDevResult<PackageScore>> getScore(String name) async {
    final result = await _fetchJson('$_kBaseUrl/api/packages/$name/score');
    return switch (result) {
      PubDevFailure<Map<String, Object?>>(:final error) => PubDevFailure(error),
      PubDevSuccess<Map<String, Object?>>(:final value) => PubDevSuccess(
        PackageScore.fromJson(value),
      ),
    };
  }

  /// Returns every published security advisory for [name] from
  /// `GET /api/packages/{name}/advisories`, in OSV format.
  ///
  /// Not version-scoped — pub.dev reports every advisory ever published
  /// against the package, regardless of which versions they affect. Callers
  /// evaluate [SecurityAdvisory.ranges] against a concrete version themselves
  /// (see `osvRangesAffectVersion`). Returns [DomainErrors.packageNotFound]
  /// when the package does not exist on pub.dev.
  Future<PubDevResult<List<SecurityAdvisory>>> getSecurityAdvisories(String name) async {
    final result = await _fetchJson('$_kBaseUrl/api/packages/$name/advisories');
    return switch (result) {
      PubDevFailure<Map<String, Object?>>(:final error) => PubDevFailure(error),
      PubDevSuccess<Map<String, Object?>>(:final value) => PubDevSuccess(
        ((value['advisories'] as List<Object?>?) ?? const [])
            .whereType<Map<String, Object?>>()
            .map(SecurityAdvisory.fromJson)
            .toList(),
      ),
    };
  }

  /// Returns full metrics for [name] from `GET /api/packages/{name}/metrics`.
  Future<PubDevResult<PackageMetrics>> getMetrics(String name) async {
    final result = await _fetchJson('$_kBaseUrl/api/packages/$name/metrics');
    return switch (result) {
      PubDevFailure<Map<String, Object?>>(:final error) => PubDevFailure(error),
      PubDevSuccess<Map<String, Object?>>(:final value) => PubDevSuccess(
        PackageMetrics.fromJson(value),
      ),
    };
  }

  /// Returns the dartdoc symbol index for [name] at [version].
  ///
  /// Fetches `GET /documentation/{name}/{version}/index.json` and parses each
  /// entry into a [DartdocSymbol]. [version] defaults to `'latest'`.
  Future<PubDevResult<List<DartdocSymbol>>> getApiIndex(
    String name, {
    String version = 'latest',
  }) async {
    final result = await _fetchJsonList('$_kBaseUrl/documentation/$name/$version/index.json');
    return switch (result) {
      PubDevFailure<List<Object?>>(:final error) => PubDevFailure(error),
      PubDevSuccess<List<Object?>>(:final value) => PubDevSuccess(
        value.whereType<Map<String, Object?>>().map(DartdocSymbol.fromJson).toList(),
      ),
    };
  }

  /// Returns the raw changelog text for [name] from the pub.dev changelog page.
  ///
  /// Fetches `GET /packages/{name}/changelog` and converts the rendered HTML to
  /// plain text with `## version` headings preserved so the caller can apply
  /// the standard Keep-a-Changelog parsing algorithm.
  Future<PubDevResult<String>> getChangelog(String name) =>
      _fetchMarkdown('$_kBaseUrl/packages/$name/changelog', HtmlToMarkdown.convert);

  /// Returns a README excerpt for [name] from the rendered documentation page.
  ///
  /// Fetches `GET /documentation/{name}/latest/` and extracts plain text from
  /// the markdown section of the rendered HTML.
  Future<PubDevResult<String>> getReadme(String name) => _fetchMarkdown(
    '$_kBaseUrl/documentation/$name/latest/',
    (html) => HtmlToMarkdown.convert(html, isolateClass: 'desc markdown', maxChars: 500),
  );

  /// Returns the plain-text content of a dartdoc symbol page for [package].
  ///
  /// Fetches `GET /documentation/{package}/{version}/{href}` and strips HTML.
  /// The [href] must come from a prior [getApiIndex] call. [version] defaults
  /// to `'latest'`. Returns [DomainErrors.symbolNotFound] when the page
  /// resolves to HTTP 404.
  Future<PubDevResult<String>> getSymbolDoc(
    String package,
    String href, {
    String version = 'latest',
  }) async {
    final url = '$_kBaseUrl/documentation/$package/$version/$href';
    String convert(String html) => HtmlToMarkdown.convert(html, isolateTag: 'main');
    final result = await _execute(
      (attempt) => _getRaw(url, htmlPreview: convert, attempt: attempt),
    );
    return switch (result) {
      PubDevFailure<String>(:final error) when error.code == DomainErrors.packageNotFound =>
        const PubDevFailure(
          DomainError(
            code: DomainErrors.symbolNotFound,
            message: 'Symbol documentation page not found.',
            suggestion: 'Verify the symbol name is correct and the package has dartdoc output.',
          ),
        ),
      PubDevFailure<String>(:final error) => PubDevFailure(error),
      PubDevSuccess<String>(:final value) => PubDevSuccess(convert(value)),
    };
  }

  /// Returns the full README text for [name] from the rendered documentation page.
  ///
  /// Fetches `GET /documentation/{name}/latest/` and extracts plain text from
  /// the markdown section of the rendered HTML without truncation. Returns an
  /// empty string when the documentation page contains no markdown section.
  Future<PubDevResult<String>> getFullReadme(String name) => _fetchMarkdown(
    '$_kBaseUrl/documentation/$name/latest/',
    (html) => HtmlToMarkdown.convert(html, isolateClass: 'desc markdown'),
  );

  /// Returns the package example text for [name] from the rendered example page.
  ///
  /// Fetches `GET /packages/{name}/example` and extracts plain text from the
  /// example section of the rendered HTML without truncation. Returns
  /// [DomainErrors.exampleNotFound] when the page contains no example section.
  Future<PubDevResult<String>> getExample(String name) async {
    final result = await _execute(
      (attempt) => _getRaw(
        '$_kBaseUrl/packages/$name/example',
        htmlPreview: _exampleMarkdown,
        attempt: attempt,
      ),
    );
    return switch (result) {
      PubDevFailure<String>(:final error) => PubDevFailure(error),
      PubDevSuccess<String>(:final value) => _exampleResult(value),
    };
  }

  /// Returns the latest stable (non-pre-release) version string for [packageName].
  ///
  /// Fetches `GET /api/packages/{name}` and scans the versions list from newest
  /// to oldest, returning the first version that does not contain a pre-release
  /// separator (`-`). Falls back to the `latest` field as a safety net when the
  /// versions list is absent or contains only pre-release entries. In that
  /// fallback case the returned version may itself be a pre-release: a package
  /// that has only ever published pre-releases sets `latest` to one.
  ///
  /// Returns [DomainErrors.packageNotFound] when the package does not exist on
  /// pub.dev, or [DomainErrors.unexpectedResponse] when no stable version can be
  /// determined from the response.
  Future<PubDevResult<String>> resolveLatestStable(String packageName) async {
    final result = await _fetchPackageInfo(packageName);
    return switch (result) {
      PubDevFailure<Map<String, Object?>>(:final error) => PubDevFailure(error),
      PubDevSuccess<Map<String, Object?>>(:final value) => _findLatestStable(value),
    };
  }

  static PubDevResult<String> _findLatestStable(Map<String, Object?> packageInfo) {
    final rawVersions = (packageInfo['versions'] as List<Object?>?) ?? const [];
    // Versions are listed oldest-to-newest; reverse to find the newest stable first.
    for (final entry in rawVersions.reversed) {
      if (entry is! Map<String, Object?>) continue;
      // Mirror the `is!` guard above: a non-null non-String `version` would
      // throw under an `as String?` cast, so skip malformed entries instead.
      final version = entry['version'];
      if (version is! String || version.isEmpty) continue;
      // Pre-release versions contain '-' (e.g. "1.0.0-beta.1").
      if (!version.contains('-')) return PubDevSuccess(version);
    }
    // Safety net for packages with no stable release found above. pub.dev's
    // `latest` is normally the newest stable version, but for a pre-release-only
    // package it holds a pre-release — so this fallback can legitimately return
    // a pre-release string.
    final latest = (packageInfo['latest'] as Map<String, Object?>?)?['version'] as String?;
    if (latest != null && latest.isNotEmpty) return PubDevSuccess(latest);
    return const PubDevFailure(_unexpectedResponse);
  }

  /// Returns every published version of [name] from `GET /api/packages/{name}`.
  ///
  /// Parses the `versions` array into [PackageVersion] values, preserving each
  /// entry's retraction flag and publish date. Entries with an empty version
  /// string are skipped. Bucketing (stable / prerelease / retracted) and
  /// newest-first ordering are the caller's responsibility.
  ///
  /// Returns [DomainErrors.packageNotFound] when the package does not exist on
  /// pub.dev, or [DomainErrors.unexpectedResponse] when the body is malformed.
  Future<PubDevResult<List<PackageVersion>>> listVersions(String name) async {
    final result = await _fetchPackageInfo(name);
    return switch (result) {
      PubDevFailure<Map<String, Object?>>(:final error) => PubDevFailure(error),
      PubDevSuccess<Map<String, Object?>>(:final value) => PubDevSuccess(
        ((value['versions'] as List<Object?>?) ?? const [])
            .whereType<Map<String, Object?>>()
            .map(PackageVersion.fromJson)
            .where((v) => v.version.isNotEmpty)
            .toList(),
      ),
    };
  }

  /// Downloads and extracts the package tarball for [name] at [version].
  ///
  /// Fetches `GET /api/packages/{name}/versions/{version}/archive.tar.gz`,
  /// decompresses the gzip layer, decodes the tar archive, and returns a
  /// `Map<String, String>` from file path (relative to the package root) to
  /// file content. Directory entries are excluded from the map.
  ///
  /// Returns [DomainErrors.packageNotFound] when the tarball endpoint returns
  /// HTTP 404. Other transient failures are retried by the [RetryPolicy].
  Future<PubDevResult<Map<String, String>>> getPackageSourceFiles(
    String name,
    String version,
  ) async {
    if (!_kSafePackageName.hasMatch(name) || !_kSafeVersionString.hasMatch(version)) {
      return const PubDevFailure(
        DomainError(
          code: DomainErrors.invalidArgument,
          message: 'Package name or version contains invalid characters.',
          suggestion:
              'Use a valid pub.dev package name (letters, digits, underscores) '
              'and a valid version string (e.g. "1.0.0").',
        ),
      );
    }

    final cachedBytes = await _tarballCache?.read(name, version);
    if (cachedBytes != null) {
      return _extractTarballFiles(cachedBytes);
    }

    final url = packageArchiveUrl(name, version);
    // Time only the download (retries included); the tarball `← pub` line is
    // logged after extraction because its file count is not known until then.
    final stopwatch = Stopwatch()..start();
    final result = await _execute(
      (attempt) => _downloadBytesWithLimit(url, maxBytes: _kMaxTarballBytes, attempt: attempt),
    );
    stopwatch.stop();
    if (result case PubDevFailure<List<int>>(:final error)) {
      return PubDevFailure(error);
    }

    final bytes = (result as PubDevSuccess<List<int>>).value;
    final extracted = _extractTarballFiles(bytes);
    if (extracted case PubDevFailure<Map<String, String>>(:final error)) {
      return PubDevFailure(error);
    }

    _logTarball(
      uri: Uri.parse(url),
      sizeBytes: bytes.length,
      fileCount: (extracted as PubDevSuccess<Map<String, String>>).value.length,
      latency: stopwatch.elapsed,
    );

    // Persist only validated tarballs so malformed downloads cannot poison
    // the cache for future requests.
    await _tarballCache?.write(name, version, bytes);

    return extracted;
  }

  /// Logs a completed tarball download as metadata only — download size and
  /// extracted file count, never any archive content. Reads the Correlation Id
  /// from the ambient [Zone] at call time; a null id or absent trace logs nothing.
  void _logTarball({
    required Uri uri,
    required int sizeBytes,
    required int fileCount,
    required Duration latency,
  }) {
    final trace = _trace;
    if (trace == null) return;
    final id = currentCorrelationId();
    if (id == null) return;
    trace.logResponse(
      id: id,
      status: 200,
      path: uri.path,
      latency: latency,
      sizeBytes: sizeBytes,
      contentType: 'tar.gz',
      fileCount: fileCount,
    );
  }

  static PubDevResult<Map<String, String>> _extractTarballFiles(List<int> bytes) {
    try {
      final decompressed = const GZipDecoder().decodeBytes(bytes);
      final archive = TarDecoder().decodeBytes(decompressed);
      final files = <String, String>{};
      for (final entry in archive) {
        if (!entry.isFile) continue;
        final content = utf8.decode(entry.content, allowMalformed: true);
        files[entry.name] = content;
      }
      return PubDevSuccess(files);
    } on Object {
      return const PubDevFailure(
        DomainError(
          code: DomainErrors.unexpectedResponse,
          message: 'Failed to decode the package tarball.',
          suggestion: 'Try again later or check the pub.dev status page.',
        ),
      );
    }
  }

  /// Converts a package example page's HTML to markdown, isolating the example
  /// tab. Shared by [getExample] and the Wire Trace preview so both render the
  /// same content from one conversion rule.
  static String _exampleMarkdown(String html) => HtmlToMarkdown.convert(
    html,
    isolateClass: 'tab-content detail-tab-example-content -active markdown-body',
  );

  static PubDevResult<String> _exampleResult(String html) {
    final example = _exampleMarkdown(html);
    if (example.isEmpty) {
      return const PubDevFailure(
        DomainError(
          code: DomainErrors.exampleNotFound,
          message: 'Package example not found.',
          suggestion: 'Check whether the package publishes an example tab on pub.dev.',
        ),
      );
    }
    return PubDevSuccess(example);
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  /// Fetches `GET /api/packages/{name}` through the Package Info Cache.
  ///
  /// [resolveLatestStable], [getPackage]'s info-half, [listVersions], and
  /// [_fetchSummary] all route through here, so the endpoint's full-metadata
  /// payload (every version included) is fetched from pub.dev at most once per
  /// [kPackageMetadataTtl] window per package name — shared across those callers
  /// and across concurrent requests. The in-flight [Future] is stored before it
  /// is awaited, so two concurrent misses for the same name share one HTTP call
  /// (single-flight via [ResponseCache.set]).
  ///
  /// A failed fetch is **never** cached: the entry is evicted so the next call
  /// gets a clean miss and retries against pub.dev, per the cache-poisoning
  /// avoidance convention. When no cache was injected the call falls through
  /// directly to [_fetchJson] with no memoisation.
  Future<PubDevResult<Map<String, Object?>>> _fetchPackageInfo(String name) async {
    final cache = _packageInfoCache;
    if (cache == null) {
      return _fetchJson('$_kBaseUrl/api/packages/$name');
    }

    final cached = cache.get(name);
    if (cached != null) {
      try {
        return PubDevSuccess(await cached);
      } on Object {
        // The in-flight request sharing this future failed; fall through to
        // issue an independent request rather than replaying the failure.
      }
    }

    // Store the in-flight future before awaiting so concurrent callers for the
    // same name share this single request (cache-stampede prevention, per
    // ResponseCache's contract).
    final completer = Completer<Map<String, Object?>>();
    cache.set(name, completer.future, kPackageMetadataTtl);

    final result = await _fetchJson('$_kBaseUrl/api/packages/$name');
    switch (result) {
      case PubDevSuccess(:final value):
        completer.complete(value);
        return result;
      case PubDevFailure(:final error):
        // Unblock any concurrent waiters with an error, then evict the entry so
        // the next independent call gets a clean miss. `ignore()` registers a
        // no-op error handler so Dart does not report an unhandled Future error
        // when no concurrent caller is actually waiting on this future.
        completer.future.ignore();
        completer.completeError(StateError('package info fetch failed: ${error.code}'));
        cache.invalidate(name);
        return result;
    }
  }

  /// Fetches [url] with retry and parses the body as a JSON object.
  ///
  /// JSON parsing happens outside [RetryPolicy.execute] — see ADR-0002.
  /// Returns [PubDevFailure] with [DomainErrors.unexpectedResponse] when the
  /// body is not a JSON object.
  Future<PubDevResult<Map<String, Object?>>> _fetchJson(String url) async {
    final result = await _execute(
      (attempt) => _getRaw(url, attempt: attempt),
    );
    if (result case PubDevFailure<String>(:final error)) return PubDevFailure(error);
    final body = (result as PubDevSuccess<String>).value;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, Object?>) return PubDevSuccess(decoded);
    } on FormatException catch (_) {}
    return const PubDevFailure(_unexpectedResponse);
  }

  /// Fetches [url] with retry and parses the body as a JSON array.
  ///
  /// JSON parsing happens outside [RetryPolicy.execute] — see ADR-0002.
  /// Returns [PubDevFailure] with [DomainErrors.unexpectedResponse] when the
  /// body is not a JSON array.
  Future<PubDevResult<List<Object?>>> _fetchJsonList(String url) async {
    final result = await _execute(
      (attempt) => _getRaw(url, attempt: attempt),
    );
    if (result case PubDevFailure<String>(:final error)) return PubDevFailure(error);
    final body = (result as PubDevSuccess<String>).value;
    try {
      final decoded = jsonDecode(body);
      if (decoded is List<Object?>) return PubDevSuccess(decoded);
    } on FormatException catch (_) {}
    return const PubDevFailure(_unexpectedResponse);
  }

  /// Fetches an HTML endpoint at [url] and returns its markdown, using [convert]
  /// for both the returned value and the Wire Trace preview so the two never
  /// drift. The shared shape behind [getChangelog], [getReadme], and
  /// [getFullReadme]; endpoints that post-process the result (a 404 remap, an
  /// emptiness check) keep their own `switch` instead of calling this.
  Future<PubDevResult<String>> _fetchMarkdown(
    String url,
    String Function(String html) convert,
  ) async {
    final result = await _execute(
      (attempt) => _getRaw(url, htmlPreview: convert, attempt: attempt),
    );
    return switch (result) {
      PubDevFailure<String>(:final error) => PubDevFailure(error),
      PubDevSuccess<String>(:final value) => PubDevSuccess(convert(value)),
    };
  }

  /// Fetches [url] and returns the raw response body.
  ///
  /// [attempt] is the zero-based retry attempt (from [RetryPolicy.execute]); a
  /// value `> 0` tags the traced request line as `[retry N]`.
  ///
  /// [htmlPreview] marks [url] as an HTML endpoint and converts the raw HTML to
  /// the markdown the caller will ultimately return. When supplied, the trace
  /// logs that markdown as the response body preview together with both the raw
  /// HTML and markdown sizes — the raw HTML is never written to the trace. It is
  /// only ever invoked while tracing is active, so a disabled trace pays nothing.
  Future<String> _getRaw(
    String url, {
    String Function(String html)? htmlPreview,
    int attempt = 0,
  }) async {
    await _semaphore.acquire();
    try {
      final uri = Uri.parse(url);
      // Read the Correlation Id from the ambient Zone once per call: it is
      // stable across this method, and a null id (no traced request on the
      // stack, or tracing disabled) means nothing is built or logged. Both
      // guards below re-test `trace`/`id` so Dart promotes them to non-null.
      final trace = _trace;
      final id = trace == null ? null : currentCorrelationId();
      if (trace != null && id != null) {
        trace.logRequest(
          id: id,
          httpMethod: 'GET',
          path: _requestPath(uri),
          context: attempt > 0 ? 'retry $attempt' : null,
        );
      }
      final stopwatch = Stopwatch()..start();
      final response = await _http.get(uri, headers: const {'Accept': _kAccept}).timeout(_timeout);
      stopwatch.stop();
      if (trace != null && id != null) {
        _logHttpResponse(trace, id, uri, response, stopwatch.elapsed, htmlPreview);
      }
      if (response.statusCode == 200) return response.body;
      throw HttpStatusException(
        response.statusCode,
        path: uri.path,
        latency: stopwatch.elapsed,
      );
    } finally {
      _semaphore.release();
    }
  }

  /// Writes the `← pub` line for [response] to the Wire Trace.
  ///
  /// A successful text body is previewed up to the configured cap. For an HTML
  /// endpoint (identified by [htmlPreview]) the preview is the converted markdown
  /// annotated with both sizes; the raw HTML is never logged. A non-200 response
  /// logs status and latency only — no body — matching the authoritative format.
  void _logHttpResponse(
    WireTrace trace,
    String id,
    Uri uri,
    http.Response response,
    Duration latency,
    String Function(String html)? htmlPreview,
  ) {
    final status = response.statusCode;
    // The query lives on the request line only; the response line names the
    // bare endpoint (matches the authoritative trace format).
    final path = uri.path;
    if (status != 200) {
      // A retryable status is rendered by the RetryPolicy hooks instead — as a
      // `⚠ … retry` line while attempts remain, or a `← pub` line on give-up —
      // so logging it here too would duplicate the authoritative single line.
      if (!RetryPolicy.isRetryableStatus(status)) {
        trace.logResponse(id: id, status: status, path: path, latency: latency);
      }
      return;
    }
    final sizeBytes = response.bodyBytes.length;
    if (htmlPreview != null) {
      String markdown;
      try {
        markdown = htmlPreview(response.body);
      } on Object {
        // A preview failure must never disturb the request: fall back to
        // metadata only rather than risk writing raw HTML or throwing.
        trace.logResponse(
          id: id,
          status: status,
          path: path,
          latency: latency,
          sizeBytes: sizeBytes,
          contentType: 'HTML',
        );
        return;
      }
      trace.logResponse(
        id: id,
        status: status,
        path: path,
        latency: latency,
        sizeBytes: sizeBytes,
        markdownSizeBytes: utf8.encode(markdown).length,
        preview: trace.bodyPreview(markdown),
      );
      return;
    }
    trace.logResponse(
      id: id,
      status: status,
      path: path,
      latency: latency,
      sizeBytes: sizeBytes,
      contentType: _shortContentType(response.headers['content-type']),
      preview: trace.bodyPreview(response.body),
    );
  }

  /// Runs [operation] under the [RetryPolicy] with the Wire Trace hooks wired in.
  ///
  /// Every endpoint fetch goes through here so retry/give-up logging is attached
  /// in one place rather than repeated at each call site. The hooks are no-ops
  /// when tracing is disabled or no request is on the stack.
  Future<PubDevResult<T>> _execute<T>(Future<T> Function(int attempt) operation) =>
      _retry.execute(operation, onRetry: _logRetry, onGiveUp: _logGiveUp);

  /// Logs a retryable pub.dev failure and its backoff to the Wire Trace.
  ///
  /// Passed as `onRetry` to [RetryPolicy.execute]; reads the Correlation Id from
  /// the ambient [Zone] at call time. A [failure] missing its path or latency
  /// (no live response to measure) is skipped rather than logged incompletely.
  void _logRetry(HttpStatusException failure, int retryNumber, Duration backoff) {
    final trace = _trace;
    if (trace == null) return;
    final id = currentCorrelationId();
    final path = failure.path;
    final latency = failure.latency;
    if (id == null || path == null || latency == null) return;
    trace.logRetry(
      id: id,
      status: failure.statusCode,
      path: path,
      latency: latency,
      attempt: retryNumber,
      maxAttempts: _retry.maxAttempts,
      backoff: backoff,
    );
  }

  /// Logs the final retryable failure once retries are exhausted, as the plain
  /// `← pub {status}` response line the fetch helpers suppressed for retryable
  /// statuses (`_logHttpResponse` defers them here to avoid double-logging).
  ///
  /// Passed as `onGiveUp` to [RetryPolicy.execute]; like [_logRetry] it reads the
  /// ambient Correlation Id and skips a failure with no path or latency to render.
  void _logGiveUp(HttpStatusException failure) {
    final trace = _trace;
    if (trace == null) return;
    final id = currentCorrelationId();
    final path = failure.path;
    final latency = failure.latency;
    if (id == null || path == null || latency == null) return;
    trace.logResponse(
      id: id,
      status: failure.statusCode,
      path: path,
      latency: latency,
    );
  }

  /// The request-line path for [uri]: the path with its query string appended
  /// (the full URL minus scheme and host), so the exact upstream endpoint —
  /// including search parameters — is legible in the trace.
  static String _requestPath(Uri uri) => uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;

  /// A compact content-type label (`JSON`, `HTML`, `text`) derived from a raw
  /// `content-type` header, or `null` when the header is absent or unrecognised.
  static String? _shortContentType(String? header) {
    if (header == null) return null;
    final lower = header.toLowerCase();
    if (lower.contains('json')) return 'JSON';
    if (lower.contains('html')) return 'HTML';
    if (lower.contains('text/plain')) return 'text';
    return null;
  }

  Future<List<int>> _downloadBytesWithLimit(
    String url, {
    required int maxBytes,
    int attempt = 0,
  }) async {
    await _semaphore.acquire();
    try {
      final uri = Uri.parse(url);
      // The successful `← pub` line (size + file count) is logged by the caller
      // after extraction; here we log only the request and any error response.
      final trace = _trace;
      final id = trace == null ? null : currentCorrelationId();
      if (trace != null && id != null) {
        trace.logRequest(
          id: id,
          httpMethod: 'GET',
          path: _requestPath(uri),
          context: attempt > 0 ? 'retry $attempt' : null,
        );
      }
      final stopwatch = Stopwatch()..start();
      final request = http.Request('GET', uri);
      request.headers['Accept'] = _kAccept;

      final response = await _http.send(request).timeout(_timeout);

      if (response.statusCode != 200) {
        stopwatch.stop();
        // As in `_getRaw`, a retryable status is left to the RetryPolicy hooks so
        // it is logged exactly once (retry line or give-up response line).
        if (trace != null && id != null && !RetryPolicy.isRetryableStatus(response.statusCode)) {
          trace.logResponse(
            id: id,
            status: response.statusCode,
            path: uri.path,
            latency: stopwatch.elapsed,
          );
        }
        throw HttpStatusException(
          response.statusCode,
          path: uri.path,
          latency: stopwatch.elapsed,
        );
      }

      final bytes = BytesBuilder(copy: false);
      var receivedBytes = 0;
      final downloadDeadline = DateTime.now().add(_timeout * _kDownloadTimeoutFactor);

      // _timeout acts as a per-chunk idle deadline (stream.timeout resets on
      // every event). The deadline check below enforces a hard wall-clock cap
      // on the entire download so a slow-drip server cannot hold a semaphore
      // slot open indefinitely. Throwing inside `await for` triggers
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
    } finally {
      _semaphore.release();
    }
  }

  Future<PackageSummary?> _fetchSummary(String name) async {
    final (infoResult, scoreResult) = await (
      _fetchPackageInfo(name),
      _fetchJson('$_kBaseUrl/api/packages/$name/score'),
    ).wait;
    if (infoResult is PubDevFailure<Map<String, Object?>> ||
        scoreResult is PubDevFailure<Map<String, Object?>>) {
      return null;
    }
    final info = (infoResult as PubDevSuccess<Map<String, Object?>>).value;
    final score = (scoreResult as PubDevSuccess<Map<String, Object?>>).value;
    return PackageSummary.fromPackageAndScore(info, score);
  }

  static String? _mapSort(String sort) => switch (sort) {
    'relevance' => null,
    'likes' => 'like',
    'pubPoints' || 'pub_points' => 'points',
    'updated' => 'recent',
    _ => null,
  };
}
