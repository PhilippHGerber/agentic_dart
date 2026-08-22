/// Handler for the `compare_packages` MCP tool.
///
/// [ComparePackagesHandler] compares 2–5 packages side by side, returning a
/// [_ComparisonMatrix]. Each package's [PackageDetail] is resolved through the
/// shared `packageDetail` [KeyedCache] facade (from `CacheRegistry`, keyed by
/// `(name, version)`) after resolving its Latest Stable Version, so a prior
/// `get_package` call for the same package and resolved version is reused
/// rather than re-fetched. Requests for uncached packages are gated by the
/// pub.dev client's global concurrency limiter, which caps the number of
/// in-flight pub.dev requests across the whole server.
///
/// Domain errors are returned as [CallToolResult] with [CallToolResult.isError]
/// `true` and a structured JSON payload — exceptions are never swallowed
/// silently. When every requested package fails, a single domain error is
/// returned; otherwise failed packages appear in `errors` and are excluded
/// from the matrix.
///
/// See `issues/pub-dev-mcp/08-compare-packages-tool.md`.
///
/// The matrix also carries a best-effort `advisories` row (per-package
/// security-advisory count), sourced from the same `securityAdvisories`
/// [KeyedCache] facade `get_security_advisories` uses — see
/// `issues/fr-tools-disposition/03-advisories-passive-signal.md`. A
/// per-package advisories-fetch failure leaves that package's cell absent
/// from the row without failing the comparison.
library;

import 'package:dart_mcp/server.dart';

import '../cache/cache_registry.dart';
import '../cache/keyed_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import 'advisories_signal.dart';
import 'tool_response.dart';
import 'version_resolver.dart';

/// Handles calls to the `compare_packages` MCP tool.
///
/// Constructor dependencies are `versionResolver`, `packageDetail`, and `log`.
/// The `packageDetail` facade should be the same [KeyedCache] instance shared
/// with `GetPackageHandler` so that prior `get_package` calls are reused.
/// Packages are fetched concurrently; the pub.dev client's global concurrency
/// limiter bounds the number of simultaneous pub.dev requests.
final class ComparePackagesHandler {
  /// Creates a [ComparePackagesHandler].
  ///
  /// [versionResolver] resolves each package's Resolved Version, falling back
  /// to the Latest Stable Version. [packageDetail] is the shared [KeyedCache]
  /// facade (same instance as used by `GetPackageHandler`). [securityAdvisories]
  /// is the shared [KeyedCache] facade (same instance as `get_security_advisories`)
  /// used for the matrix's best-effort `advisories` row. [log] receives
  /// structured log events at the appropriate [LoggingLevel].
  const ComparePackagesHandler({
    required VersionResolver versionResolver,
    required KeyedCache<PackageDetailId, PackageDetail> packageDetail,
    required KeyedCache<SecurityAdvisoriesId, List<SecurityAdvisory>> securityAdvisories,
    required void Function(LoggingLevel, Object) log,
  }) : _versionResolver = versionResolver,
       _packageDetail = packageDetail,
       _securityAdvisories = securityAdvisories,
       _log = log;

  final VersionResolver _versionResolver;
  final KeyedCache<PackageDetailId, PackageDetail> _packageDetail;
  final KeyedCache<SecurityAdvisoriesId, List<SecurityAdvisory>> _securityAdvisories;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `compare_packages`.
  ///
  /// `packages` is capped at 2–5 entries by the tool's input schema. Fetches
  /// the packages concurrently; the pub.dev client's concurrency limiter
  /// (reached through `versionResolver` and `packageDetail`) bounds how many
  /// requests are in flight at once. Returns [CallToolResult.isError] `true`
  /// when all packages fail.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final packages = ((args['packages'] as List<Object?>?) ?? const [])
        .whereType<String>()
        .toList();

    _log(LoggingLevel.info, 'compare_packages: packages=${packages.join(',')}');

    final errors = <String, String>{};
    final details = <String, PackageDetail>{};

    // Fetch all packages concurrently; the PubDevClient concurrency limiter
    // bounds how many requests are actually in flight at any moment. Results
    // are folded back in request order so the response is deterministic.
    final results = await Future.wait(packages.map(_fetchPackage));
    for (var i = 0; i < packages.length; i++) {
      final package = packages[i];
      switch (results[i]) {
        case PubDevSuccess(:final value):
          details[package] = value;
        case PubDevFailure(:final error):
          _log(
            LoggingLevel.warning,
            'compare_packages: failed package=$package error=${error.code}',
          );
          errors[package] = error.code;
      }
    }

    if (details.isEmpty) {
      return ToolResponse.error(
        const DomainError(
          code: DomainErrors.serviceUnavailable,
          message: 'All requested packages failed to load.',
          suggestion: 'Verify that the package names are correct and retry.',
        ),
      );
    }

    final advisoryCounts = await _fetchAdvisoryCounts(details.keys);

    return ToolResponse.ok(
      _ComparisonMatrix(
        packages: packages,
        errors: errors,
        matrix: _buildMatrix(details, advisoryCounts),
      ).toJson(),
    );
  }

  // ── Best-effort advisories row ───────────────────────────────────────────────

  /// Fetches a best-effort advisory count for every package in [names],
  /// concurrently. A package whose advisories fetch fails (domain failure or
  /// an escaping exception) is absent from the returned map rather than
  /// failing the comparison.
  Future<Map<String, int>> _fetchAdvisoryCounts(Iterable<String> names) async {
    final counts = <String, int>{};
    final results = await Future.wait(
      names.map((name) async => MapEntry(name, await _fetchAdvisoryCount(name))),
    );
    for (final entry in results) {
      if (entry.value case final count?) counts[entry.key] = count;
    }
    return counts;
  }

  /// Fetches the advisory count for one [package], or `null` on any failure.
  Future<int?> _fetchAdvisoryCount(String package) => fetchAdvisoriesBestEffort(
    cache: _securityAdvisories,
    package: package,
    tool: 'compare_packages',
    log: _log,
    onSuccess: (advisories) => advisories.length,
  );

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
  /// caught by the pub.dev client's retry policy) would abort the *entire*
  /// comparison rather than demote a single package into the `errors` map.
  /// Guaranteeing a [PubDevResult] return keeps the documented
  /// graceful-degradation contract intact.
  Future<PubDevResult<PackageDetail>> _fetchPackage(String package) async {
    try {
      final versionResult = await _versionResolver.resolve(
        package: package,
        tool: 'compare_packages',
      );
      switch (versionResult) {
        case PubDevFailure(:final error):
          return PubDevFailure(error);
        case PubDevSuccess(:final value):
          return await _packageDetail.resolve((
            name: package,
            version: value,
            pinned: false,
          ));
      }
    } on Object catch (error) {
      _log(
        LoggingLevel.warning,
        'compare_packages: unexpected error package=$package error=$error',
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
    Map<String, int> advisoryCounts,
  ) {
    final matrix = <String, Map<String, Object?>>{};
    for (final entry in details.entries) {
      final pkg = entry.key;
      final d = entry.value;
      _set(matrix, 'package', pkg, d.name);
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
      if (advisoryCounts[pkg] case final count?) _set(matrix, 'advisories', pkg, count);
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
