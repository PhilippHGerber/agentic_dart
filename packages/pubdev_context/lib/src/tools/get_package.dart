/// Handler for the `get_package` MCP tool.
///
/// Returns a full [PackageDetail] for one package, optionally at a pinned
/// version. When `version` is omitted the handler resolves the latest stable
/// version via [PubDevClient.resolveLatestStable] so that the cache key is
/// always version-anchored (e.g. `package:http:1.6.0`, never `package:http:`).
///
/// Every success response includes `resolvedVersion` as its first JSON key,
/// reflecting the exact semver used — whether the caller supplied it or the
/// server inferred it.
///
/// Cache key format: `package:<name>:<resolvedVersion>`.
/// Cache hits are logged at [LoggingLevel.debug].
///
/// Domain errors are returned as [CallToolResult] with [CallToolResult.isError]
/// `true` and a structured JSON payload — exceptions are never swallowed silently.
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../cache/memory_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import '../data/pub_client.dart';

/// Handles calls to the `get_package` MCP tool.
///
/// Resolves the latest stable version when no version is supplied so that
/// the cache key is always pinned to a concrete semver. Consults the cache
/// before issuing HTTP requests; stores successful results with
/// [kPackageMetadataTtl]. Error results are not cached so transient failures
/// can be retried by the next call.
final class GetPackageHandler {
  /// Creates a [GetPackageHandler].
  ///
  /// [client] is the pub.dev HTTP gateway. [cache] is the shared TTL store.
  /// [log] receives structured log events at the appropriate [LoggingLevel].
  const GetPackageHandler({
    required PubDevClient client,
    required ResponseCache<PackageDetail> cache,
    required void Function(LoggingLevel, Object) log,
  }) : _client = client,
       _cache = cache,
       _log = log;

  final PubDevClient _client;
  final ResponseCache<PackageDetail> _cache;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `get_package`.
  ///
  /// Resolves the version (via [PubDevClient.resolveLatestStable] when absent),
  /// consults the cache, or fetches from pub.dev. Returns
  /// [CallToolResult.isError] `true` on any domain failure.
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
    if (suppliedVersion != null) {
      resolvedVersion = suppliedVersion;
    } else {
      _log(LoggingLevel.info, 'get_package: resolving latest stable version for $name');
      switch (await _client.resolveLatestStable(name)) {
        case PubDevFailure(:final error):
          return _domainError(error);
        case PubDevSuccess(:final value):
          resolvedVersion = value;
      }
      _log(LoggingLevel.debug, 'get_package: resolved version=$resolvedVersion');
    }

    // ── Cache lookup ───────────────────────────────────────────────────────────

    final cacheKey = 'package:$name:$resolvedVersion';
    final cached = _cache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'get_package: cache hit key=$cacheKey');
      return _success(await cached, resolvedVersion);
    }

    _log(LoggingLevel.debug, 'get_package: cache miss key=$cacheKey');
    _log(LoggingLevel.info, 'get_package: HTTP request name=$name version=$resolvedVersion');

    // ── Fetch ──────────────────────────────────────────────────────────────────

    // Trade-off: when the version was omitted we resolved latest-stable above
    // (for a version-anchored cache key) and now call getPackage, which fetches
    // the same latest metadata again — one extra lightweight GET. We accept this
    // for a stable cache key and simpler control flow rather than threading the
    // already-resolved detail through the resolver (see plan W4).
    final result = suppliedVersion != null
        ? await _client.getPackageVersion(name, resolvedVersion)
        : await _client.getPackage(name);

    switch (result) {
      case PubDevSuccess(:final value):
        _cache.set(cacheKey, Future.value(value), kPackageMetadataTtl);
        return _success(value, resolvedVersion);
      case PubDevFailure(:final error):
        return _domainError(error);
    }
  }

  static CallToolResult _success(PackageDetail detail, String resolvedVersion) => CallToolResult(
    content: [TextContent(text: jsonEncode(_detailToJson(detail, resolvedVersion)))],
  );

  static CallToolResult _domainError(DomainError error) => CallToolResult(
    content: [TextContent(text: error.toJsonString())],
    isError: true,
  );

  static Map<String, Object?> _detailToJson(PackageDetail d, String resolvedVersion) => {
    'resolvedVersion': resolvedVersion,
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
