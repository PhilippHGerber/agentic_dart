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
/// Domain errors are returned as [CallToolResult] with [CallToolResult.isError]
/// `true` and a structured JSON payload — exceptions are never swallowed silently.
library;

import 'package:dart_mcp/server.dart';

import '../cache/cache_registry.dart';
import '../cache/keyed_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
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
  /// caches [PackageDetail] by [PackageDetailId]. [log] receives structured
  /// log events at the appropriate [LoggingLevel].
  const GetPackageHandler({
    required VersionResolver versionResolver,
    required KeyedCache<PackageDetailId, PackageDetail> packageDetail,
    required void Function(LoggingLevel, Object) log,
  }) : _versionResolver = versionResolver,
       _packageDetail = packageDetail,
       _log = log;

  final VersionResolver _versionResolver;
  final KeyedCache<PackageDetailId, PackageDetail> _packageDetail;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `get_package`.
  ///
  /// Resolves the version (via [VersionResolver] when absent), then resolves
  /// [PackageDetail] through `packageDetail`. Returns [CallToolResult.isError]
  /// `true` on any domain failure.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final name = (args['name'] as String?) ?? '';
    final suppliedVersion = args['version'] as String?;

    _log(
      LoggingLevel.info,
      'get_package: name=$name${suppliedVersion != null ? ' version=$suppliedVersion' : ''}',
    );

    // ── Resolve version ────────────────────────────────────────────────────────

    final String resolvedVersion;
    switch (await _versionResolver.resolve(
      package: name,
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
      name: name,
      version: resolvedVersion,
      pinned: suppliedVersion != null,
    ));

    switch (result) {
      case PubDevSuccess(:final value):
        return ToolResponse.ok(_detailToJson(value), resolvedVersion: resolvedVersion);
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
    }
  }

  static Map<String, Object?> _detailToJson(PackageDetail d) => {
    'name': d.name,
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
  };
}
