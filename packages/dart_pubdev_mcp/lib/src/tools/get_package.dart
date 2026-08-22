/// Handler for the `get_package` MCP tool.
///
/// Returns a full [PackageDetail] for one package, optionally at a pinned
/// version. When `version` is omitted the handler resolves the latest stable
/// version via [VersionResolver] so that the identity passed to
/// [PackageDetailId] is always version-anchored (e.g. `(http, 1.6.0)`, never a
/// version-less identity).
///
/// Every success response includes `resolvedVersion` as its first JSON key,
/// reflecting the exact semver used — whether the caller supplied it or the
/// server inferred it.
///
/// The `packageDetail` [KeyedCache] (built by `CacheRegistry`) owns the
/// cache-key format, TTL, and skip-on-failure policy, and is shared with
/// `compare_packages` so the same package's metadata is fetched once.
///
/// Also attaches a best-effort `advisories` summary (count, ids, whether the
/// Resolved Version is affected) sourced from the same `securityAdvisories`
/// [KeyedCache] facade `get_security_advisories` uses — see
/// `issues/fr-tools-disposition/03-advisories-passive-signal.md`. A failed
/// advisories fetch never fails this tool; the field is simply omitted.
///
/// Domain errors are returned as [CallToolResult] with [CallToolResult.isError]
/// `true` and a structured JSON payload — exceptions are never swallowed silently.
library;

import 'package:dart_mcp/server.dart';

import '../cache/cache_registry.dart';
import '../cache/keyed_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import '../data/osv_range_evaluator.dart';
import 'advisories_signal.dart';
import 'sdk_package_guard.dart';
import 'tool_response.dart';
import 'version_resolver.dart';

/// Handles calls to the `get_package` MCP tool.
///
/// Resolves the latest stable version when no version is supplied so that the
/// identity passed to `packageDetail` is always pinned to a concrete semver.
final class GetPackageHandler {
  /// Creates a [GetPackageHandler].
  ///
  /// [versionResolver] resolves the Resolved Version, falling back to the
  /// Latest Stable Version when the caller omits one. [packageDetail] is the
  /// shared [KeyedCache] facade (from `CacheRegistry`) that resolves and
  /// caches [PackageDetail] by [PackageDetailId]. [securityAdvisories] is the
  /// shared [KeyedCache] facade (same instance as `get_security_advisories`)
  /// used for the best-effort `advisories` summary. [log] receives structured
  /// log events at the appropriate [LoggingLevel].
  const GetPackageHandler({
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

  /// Handles a [CallToolRequest] for `get_package`.
  ///
  /// Resolves the version (via [VersionResolver] when absent), then resolves
  /// [PackageDetail] through `packageDetail`. Returns [CallToolResult.isError]
  /// `true` on any domain failure.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final package = (args['package'] as String?) ?? '';
    final suppliedVersion = args['version'] as String?;

    // Checked before anything else — including an explicit `version` — so an
    // SDK package name (e.g. "flutter") never reaches VersionResolver/PubDevClient.
    if (sdkPackageGuardError(package) case final error?) return ToolResponse.error(error);

    _log(
      LoggingLevel.info,
      'get_package: package=$package${suppliedVersion != null ? ' version=$suppliedVersion' : ''}',
    );

    // ── Resolve version ────────────────────────────────────────────────────────

    final String resolvedVersion;
    switch (await _versionResolver.resolve(
      package: package,
      supplied: suppliedVersion,
      tool: 'get_package',
    )) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        resolvedVersion = value;
    }

    // ── Resolve package detail ──────────────────────────────────────────────────

    final result = await _packageDetail.resolve((
      name: package,
      version: resolvedVersion,
      pinned: suppliedVersion != null,
    ));

    switch (result) {
      case PubDevSuccess(:final value):
        final advisories = await _fetchAdvisoriesSummary(package, resolvedVersion);
        return ToolResponse.ok(
          _detailToJson(value, advisories),
          resolvedVersion: resolvedVersion,
        );
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
    }
  }

  // ── Best-effort advisories summary ──────────────────────────────────────────

  /// Fetches a best-effort advisories summary for [package], evaluated against
  /// [resolvedVersion]. Returns `null` on any failure — a domain failure from
  /// `securityAdvisories` or an exception escaping the fetch — so a failed
  /// advisories lookup never fails the parent `get_package` call.
  Future<Map<String, Object?>?> _fetchAdvisoriesSummary(
    String package,
    String resolvedVersion,
  ) => fetchAdvisoriesBestEffort(
    cache: _securityAdvisories,
    package: package,
    tool: 'get_package',
    log: _log,
    onSuccess: (advisories) => {
      'count': advisories.length,
      'ids': advisories.map((a) => a.id).toList(),
      'affectsResolvedVersion': advisories.any(
        (a) => osvRangesAffectVersion(a.ranges, resolvedVersion),
      ),
    },
  );

  static Map<String, Object?> _detailToJson(PackageDetail d, Map<String, Object?>? advisories) => {
    'package': d.name,
    'version': d.version,
    'description': d.description,
    'verified': d.verified,
    if (d.publishedAt case final ts?) 'publishedAt': ts.toIso8601String(),
    'activeMaintenance': d.activeMaintenance,
    'likes': d.score.likes,
    'pubPoints': d.score.pubPoints,
    'popularity': d.score.popularity,
    'sdkConstraints': {
      'dart': d.sdkConstraints.dart,
      if (d.sdkConstraints.flutter != null) 'flutter': d.sdkConstraints.flutter,
    },
    'platforms': d.platforms,
    'topics': d.topics,
    'isFlutterFavorite': d.isFlutterFavorite,
    'dependencies': d.dependencies,
    'devDependencies': d.devDependencies,
    'versionsRecent': d.versionsRecent,
    if (d.publisher != null) 'publisher': d.publisher,
    if (d.license != null) 'license': d.license,
    if (d.readmeExcerpt != null) 'readmeExcerpt': d.readmeExcerpt,
    if (d.repository != null) 'repository': d.repository,
    'advisories': ?advisories,
  };
}
