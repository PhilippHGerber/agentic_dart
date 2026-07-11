/// Handler for the `compare_packages` MCP tool.
///
/// [ComparePackagesHandler] compares 2–5 packages side by side, returning a
/// [_ComparisonMatrix]. Each package's [PackageDetail] is resolved through the
/// shared `packageDetail` [KeyedCache] facade (from `CacheRegistry`, keyed by
/// `(name, version)`) after resolving its Latest Stable Version, so a prior
/// `get_package` call for the same package and resolved version is reused
/// rather than re-fetched. Requests for uncached packages are gated by the
/// global concurrency limiter inside [PubDevClient], which caps the number of
/// in-flight pub.dev requests across the whole server.
///
/// Domain errors are returned as [CallToolResult] with [CallToolResult.isError]
/// `true` and a structured JSON payload — exceptions are never swallowed
/// silently. When every requested package fails, a single domain error is
/// returned; otherwise failed packages appear in `errors` and are excluded
/// from the matrix.
///
/// See `issues/pub-dev-mcp/08-compare-packages-tool.md`.
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../cache/cache_registry.dart';
import '../cache/keyed_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import '../data/pub_client.dart';

/// Handles calls to the `compare_packages` MCP tool.
///
/// Constructor dependencies are `client`, `packageDetail`, and `log`. The
/// `packageDetail` facade should be the same [KeyedCache] instance shared with
/// `GetPackageHandler` so that prior `get_package` calls are reused. Packages
/// are fetched concurrently; the global concurrency limiter inside
/// [PubDevClient] bounds the number of simultaneous pub.dev requests.
final class ComparePackagesHandler {
  /// Creates a [ComparePackagesHandler].
  ///
  /// [client] is the pub.dev HTTP gateway, used for Latest Stable Version
  /// resolution. [packageDetail] is the shared [KeyedCache] facade (same
  /// instance as used by `GetPackageHandler`). [log] receives structured log
  /// events at the appropriate [LoggingLevel].
  const ComparePackagesHandler({
    required PubDevClient client,
    required KeyedCache<PackageDetailId, PackageDetail> packageDetail,
    required void Function(LoggingLevel, Object) log,
  }) : _client = client,
       _packageDetail = packageDetail,
       _log = log;

  final PubDevClient _client;
  final KeyedCache<PackageDetailId, PackageDetail> _packageDetail;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `compare_packages`.
  ///
  /// Validates that `names` contains between 2 and 5 entries. Fetches the
  /// packages concurrently; the [PubDevClient] concurrency limiter bounds how
  /// many requests are in flight at once. Returns [CallToolResult.isError]
  /// `true` when all packages fail or when input validation fails.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final names = ((args['names'] as List<Object?>?) ?? const []).whereType<String>().toList();

    if (names.length < 2) {
      return _domainError(
        const DomainError(
          code: DomainErrors.invalidArgument,
          message: 'names must contain at least 2 package names.',
          suggestion: 'Provide between 2 and 5 package names in the names array.',
        ),
      );
    }
    if (names.length > 5) {
      return _domainError(
        const DomainError(
          code: DomainErrors.invalidArgument,
          message: 'names must not exceed 5 package names.',
          suggestion: 'Provide between 2 and 5 package names in the names array.',
        ),
      );
    }

    _log(LoggingLevel.info, 'compare_packages: names=${names.join(',')}');

    final errors = <String, String>{};
    final details = <String, PackageDetail>{};

    // Fetch all packages concurrently; the PubDevClient concurrency limiter
    // bounds how many requests are actually in flight at any moment. Results
    // are folded back in request order so the response is deterministic.
    final results = await Future.wait(names.map(_fetchPackage));
    for (var i = 0; i < names.length; i++) {
      final name = names[i];
      switch (results[i]) {
        case PubDevSuccess(:final value):
          details[name] = value;
        case PubDevFailure(:final error):
          _log(
            LoggingLevel.warning,
            'compare_packages: failed name=$name error=${error.code}',
          );
          errors[name] = error.code;
      }
    }

    if (details.isEmpty) {
      return _domainError(
        const DomainError(
          code: DomainErrors.serviceUnavailable,
          message: 'All requested packages failed to load.',
          suggestion: 'Verify that the package names are correct and retry.',
        ),
      );
    }

    return _success(
      _ComparisonMatrix(
        packages: names,
        errors: errors,
        matrix: _buildMatrix(details),
      ),
    );
  }

  /// Fetches one package, mapping any thrown error to a [PubDevFailure].
  ///
  /// Resolves the Latest Stable Version first — a Package Info Cache hit under
  /// ADR-0004, not a fresh pub.dev round-trip — so the subsequent
  /// `packageDetail` lookup is version-anchored and shares its entry with
  /// `get_package`. A resolve failure demotes into the caller's `errors` map
  /// exactly as a fetch failure does, preserving graceful degradation.
  ///
  /// This handler fans out across [Future.wait]; an exception escaping here
  /// (e.g. a `TimeoutException` from the README fetch or a socket error not
  /// caught by [PubDevClient]'s [RetryPolicy]) would abort the *entire*
  /// comparison rather than demote a single package into the `errors` map.
  /// Guaranteeing a [PubDevResult] return keeps the documented
  /// graceful-degradation contract intact.
  Future<PubDevResult<PackageDetail>> _fetchPackage(String name) async {
    try {
      final versionResult = await _client.resolveLatestStable(name);
      switch (versionResult) {
        case PubDevFailure(:final error):
          return PubDevFailure(error);
        case PubDevSuccess(:final value):
          return await _packageDetail.resolve((
            name: name,
            version: value,
            pinned: false,
          ));
      }
    } on Object catch (error) {
      _log(
        LoggingLevel.warning,
        'compare_packages: unexpected error name=$name error=$error',
      );
      return const PubDevFailure(
        DomainError(
          code: DomainErrors.serviceUnavailable,
          message: 'Failed to fetch package metadata from pub.dev.',
          suggestion: 'Check your network connection and retry.',
        ),
      );
    }
  }

  static Map<String, Map<String, Object?>> _buildMatrix(
    Map<String, PackageDetail> details,
  ) {
    final matrix = <String, Map<String, Object?>>{};
    for (final entry in details.entries) {
      final pkg = entry.key;
      final d = entry.value;
      _set(matrix, 'name', pkg, d.name);
      _set(matrix, 'version', pkg, d.version);
      _set(matrix, 'description', pkg, d.description);
      _set(matrix, 'likes', pkg, d.score.likes);
      _set(matrix, 'pubPoints', pkg, d.score.pubPoints);
      _set(matrix, 'popularity', pkg, d.score.popularity);
      _set(matrix, 'verified', pkg, d.verified);
      _set(matrix, 'platforms', pkg, d.platforms);
      _set(matrix, 'topics', pkg, d.topics);
      _set(matrix, 'isFlutterFavorite', pkg, d.isFlutterFavorite);
      _set(matrix, 'activeMaintenance', pkg, d.activeMaintenance);
      _set(matrix, 'daysSinceUpdate', pkg, _daysSince(d.publishedAt));
      _set(matrix, 'license', pkg, d.license);
      _set(matrix, 'publisher', pkg, d.publisher);
      _set(matrix, 'sdkConstraints.dart', pkg, d.sdkConstraints.dart);
      _set(matrix, 'sdkConstraints.flutter', pkg, d.sdkConstraints.flutter);
      _set(matrix, 'dependencies', pkg, d.dependencies.length);
    }
    return matrix;
  }

  static void _set(
    Map<String, Map<String, Object?>> matrix,
    String field,
    String pkg,
    Object? value,
  ) => (matrix[field] ??= {})[pkg] = value;

  static int _daysSince(DateTime? publishedAt) {
    if (publishedAt == null) return 0;
    return DateTime.now().difference(publishedAt).inDays;
  }

  static CallToolResult _success(_ComparisonMatrix m) =>
      CallToolResult(content: [TextContent(text: jsonEncode(m.toJson()))]);

  static CallToolResult _domainError(DomainError error) => CallToolResult(
    content: [TextContent(text: error.toJsonString())],
    isError: true,
  );
}

/// The result payload of the `compare_packages` tool.
///
/// [packages] lists all requested package names in the original order.
/// [errors] maps each failed package name to its domain error code; it is
/// always present but may be an empty map when all packages succeed.
/// [matrix] maps each field name to a map of package name → value; packages
/// listed in [errors] are excluded from [matrix].
final class _ComparisonMatrix {
  const _ComparisonMatrix({
    required this.packages,
    required this.errors,
    required this.matrix,
  });

  /// All requested package names in request order.
  final List<String> packages;

  /// Maps failed package names to their domain error codes.
  final Map<String, String> errors;

  /// Maps field names to per-package values for all successful packages.
  final Map<String, Map<String, Object?>> matrix;

  /// Returns this matrix as a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'packages': packages,
    'errors': errors,
    'matrix': matrix,
  };
}
