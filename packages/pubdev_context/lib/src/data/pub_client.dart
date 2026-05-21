/// HTTP gateway to the pub.dev public REST API.
///
/// All network concerns — URL construction, response parsing, error mapping,
/// and retry logic — are encapsulated here. Raw HTTP and JSON never escape
/// this module; every public method returns a typed [PubDevResult].
library;

import 'dart:async' show TimeoutException;
import 'dart:convert';

import 'package:http/http.dart' as http;

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
  /// Returns [PubDevSuccess] on the first successful response, or
  /// [PubDevFailure] once retries are exhausted or a non-retryable error
  /// is encountered.
  Future<PubDevResult<T>> execute<T>(Future<T> Function() operation) async {
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
        return PubDevSuccess(await operation());
      } on TimeoutException {
        failures.add(_timeoutSentinel);
      } on HttpStatusException catch (e) {
        final retryable = _retryStatusCodes.contains(e.statusCode);
        final clientError = e.statusCode >= 400 && e.statusCode < 500 && e.statusCode != 429;
        if (!retryable || clientError) {
          return PubDevFailure(_errorForStatus(e.statusCode));
        }
        failures.add(e.statusCode);
      }
    }

    return PubDevFailure(_exhaustedError(failures));
  }

  static DomainError _errorForStatus(int statusCode) => switch (statusCode) {
    404 => const DomainError(
      error: DomainErrors.packageNotFound,
      message: 'Package not found on pub.dev.',
      suggestion: 'Verify the package name and try again.',
      docs: 'https://pub.dev',
    ),
    429 => const DomainError(
      error: DomainErrors.rateLimited,
      message: 'pub.dev rate-limited this request.',
      suggestion: 'Wait a moment and retry.',
    ),
    _ when statusCode >= 500 => const DomainError(
      error: DomainErrors.serviceUnavailable,
      message: 'pub.dev is temporarily unavailable.',
      suggestion: 'Try again in a few seconds.',
    ),
    _ => DomainError(
      error: 'http_error_$statusCode',
      message: 'pub.dev returned HTTP $statusCode.',
      suggestion: 'Check the pub.dev status page.',
    ),
  };

  static DomainError _exhaustedError(List<int> failures) {
    if (failures.every((c) => c == _timeoutSentinel)) {
      return const DomainError(
        error: DomainErrors.requestTimeout,
        message: 'pub.dev did not respond within the allotted time.',
        suggestion: 'Check your network connection and try again.',
      );
    }
    if (failures.every((c) => c == 429)) {
      return const DomainError(
        error: DomainErrors.rateLimited,
        message: 'pub.dev rate-limited all retry attempts.',
        suggestion: 'Wait a moment and retry.',
      );
    }
    if (failures.every((c) => c >= 500)) {
      return const DomainError(
        error: DomainErrors.serviceUnavailable,
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
class HttpStatusException implements Exception {
  /// Creates an exception for the given HTTP [statusCode].
  const HttpStatusException(this.statusCode);

  /// The HTTP status code that caused the failure.
  final int statusCode;
}

// ─── PubDevClient ─────────────────────────────────────────────────────────────

const _kBaseUrl = 'https://pub.dev';
const _kAccept = 'application/vnd.pub.v2+json';

const _unexpectedResponse = DomainError(
  error: DomainErrors.unexpectedResponse,
  message: 'pub.dev returned an unexpected response format.',
  suggestion: 'Try again later or check the pub.dev status page.',
);

/// HTTP client for the pub.dev public REST API.
///
/// Every method maps to one or more pub.dev endpoints and returns a typed
/// [PubDevResult]. No raw HTTP or JSON escapes this class. All requests include
/// the `Accept: application/vnd.pub.v2+json` header. Retry behaviour is
/// delegated to the [RetryPolicy] supplied at construction time.
final class PubDevClient {
  /// Creates a [PubDevClient].
  ///
  /// Supply [httpClient] and [retryPolicy] to override the defaults — useful
  /// for testing without live network calls. [requestTimeout] sets the deadline
  /// for each individual HTTP call; the [RetryPolicy] may issue multiple calls
  /// up to [RetryPolicy.maxAttempts] before returning a failure.
  PubDevClient({
    http.Client? httpClient,
    RetryPolicy? retryPolicy,
    Duration requestTimeout = const Duration(seconds: 10),
  }) : _http = httpClient ?? http.Client(),
       _retry = retryPolicy ?? RetryPolicy(),
       _timeout = requestTimeout;

  final http.Client _http;
  final RetryPolicy _retry;
  final Duration _timeout;

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
      _fetchJson('$_kBaseUrl/api/packages/$name'),
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
      final html = await _getRaw('$_kBaseUrl/documentation/$name/latest/');
      readmeExcerpt = HtmlToMarkdown.convert(html, isolateClass: 'desc markdown', maxChars: 500);
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
  /// Sort values: `relevance` (default), `likes`, `pub_points`, `updated`.
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

  /// Returns the dartdoc symbol index for [name].
  ///
  /// Fetches `GET /documentation/{name}/latest/index.json` and parses each
  /// entry into a [DartdocSymbol].
  Future<PubDevResult<List<DartdocSymbol>>> getApiIndex(String name) async {
    final result = await _fetchJsonList('$_kBaseUrl/documentation/$name/latest/index.json');
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
  Future<PubDevResult<String>> getChangelog(String name) async {
    final result = await _retry.execute(
      () => _getRaw('$_kBaseUrl/packages/$name/changelog'),
    );
    return switch (result) {
      PubDevFailure<String>(:final error) => PubDevFailure(error),
      PubDevSuccess<String>(:final value) => PubDevSuccess(HtmlToMarkdown.convert(value)),
    };
  }

  /// Returns a README excerpt for [name] from the rendered documentation page.
  ///
  /// Fetches `GET /documentation/{name}/latest/` and extracts plain text from
  /// the markdown section of the rendered HTML.
  Future<PubDevResult<String>> getReadme(String name) async {
    final result = await _retry.execute(
      () => _getRaw('$_kBaseUrl/documentation/$name/latest/'),
    );
    return switch (result) {
      PubDevFailure<String>(:final error) => PubDevFailure(error),
      PubDevSuccess<String>(:final value) => PubDevSuccess(
        HtmlToMarkdown.convert(value, isolateClass: 'desc markdown', maxChars: 500),
      ),
    };
  }

  /// Returns the plain-text content of a dartdoc symbol page for [package].
  ///
  /// Fetches `GET /documentation/{package}/latest/{href}` and strips HTML.
  /// The [href] must come from a prior [getApiIndex] call. Returns
  /// [DomainErrors.symbolNotFound] when the page resolves to HTTP 404.
  Future<PubDevResult<String>> getSymbolDoc(String package, String href) async {
    final url = '$_kBaseUrl/documentation/$package/latest/$href';
    final result = await _retry.execute(() => _getRaw(url));
    return switch (result) {
      PubDevFailure<String>(:final error) when error.error == DomainErrors.packageNotFound =>
        const PubDevFailure(
          DomainError(
            error: DomainErrors.symbolNotFound,
            message: 'Symbol documentation page not found.',
            suggestion:
                'Verify the href came from search_api_symbols and the package has dartdoc output.',
          ),
        ),
      PubDevFailure<String>(:final error) => PubDevFailure(error),
      PubDevSuccess<String>(:final value) => PubDevSuccess(
        HtmlToMarkdown.convert(value, isolateTag: 'main'),
      ),
    };
  }

  /// Returns the full README text for [name] from the rendered documentation page.
  ///
  /// Fetches `GET /documentation/{name}/latest/` and extracts plain text from
  /// the markdown section of the rendered HTML without truncation. Returns an
  /// empty string when the documentation page contains no markdown section.
  Future<PubDevResult<String>> getFullReadme(String name) async {
    final result = await _retry.execute(
      () => _getRaw('$_kBaseUrl/documentation/$name/latest/'),
    );
    return switch (result) {
      PubDevFailure<String>(:final error) => PubDevFailure(error),
      PubDevSuccess<String>(:final value) => PubDevSuccess(
        HtmlToMarkdown.convert(value, isolateClass: 'desc markdown'),
      ),
    };
  }

  /// Returns the package example text for [name] from the rendered example page.
  ///
  /// Fetches `GET /packages/{name}/example` and extracts plain text from the
  /// example section of the rendered HTML without truncation. Returns
  /// [DomainErrors.exampleNotFound] when the page contains no example section.
  Future<PubDevResult<String>> getExample(String name) async {
    final result = await _retry.execute(() => _getRaw('$_kBaseUrl/packages/$name/example'));
    return switch (result) {
      PubDevFailure<String>(:final error) => PubDevFailure(error),
      PubDevSuccess<String>(:final value) => _exampleResult(value),
    };
  }

  static PubDevResult<String> _exampleResult(String html) {
    final example = HtmlToMarkdown.convert(
      html,
      isolateClass: 'tab-content detail-tab-example-content -active markdown-body',
    );
    if (example.isEmpty) {
      return const PubDevFailure(
        DomainError(
          error: DomainErrors.exampleNotFound,
          message: 'Package example not found.',
          suggestion: 'Check whether the package publishes an example tab on pub.dev.',
        ),
      );
    }
    return PubDevSuccess(example);
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  /// Fetches [url] with retry and parses the body as a JSON object.
  ///
  /// JSON parsing happens outside [RetryPolicy.execute] — see ADR-0002.
  /// Returns [PubDevFailure] with [DomainErrors.unexpectedResponse] when the
  /// body is not a JSON object.
  Future<PubDevResult<Map<String, Object?>>> _fetchJson(String url) async {
    final result = await _retry.execute(() => _getRaw(url));
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
    final result = await _retry.execute(() => _getRaw(url));
    if (result case PubDevFailure<String>(:final error)) return PubDevFailure(error);
    final body = (result as PubDevSuccess<String>).value;
    try {
      final decoded = jsonDecode(body);
      if (decoded is List<Object?>) return PubDevSuccess(decoded);
    } on FormatException catch (_) {}
    return const PubDevFailure(_unexpectedResponse);
  }

  Future<String> _getRaw(String url) async {
    final response = await _http
        .get(Uri.parse(url), headers: const {'Accept': _kAccept})
        .timeout(_timeout);
    if (response.statusCode == 200) return response.body;
    throw HttpStatusException(response.statusCode);
  }

  Future<PackageSummary?> _fetchSummary(String name) async {
    final (infoResult, scoreResult) = await (
      _fetchJson('$_kBaseUrl/api/packages/$name'),
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
    'pub_points' => 'points',
    'updated' => 'recent',
    _ => null,
  };
}
