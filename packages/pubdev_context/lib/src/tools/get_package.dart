/// Handler for the `get_package` MCP tool.
///
/// Returns a full [PackageDetail] for one package, optionally at a pinned
/// version. Merges metadata from `/api/packages/{name}`, scores from
/// `/api/packages/{name}/score`, and a README excerpt from the docs page
/// in a single logical call. Results are cached with a [kPackageMetadataTtl]
/// TTL.
///
/// Cache key format: `package:<name>:<version>` (version is empty for latest).
/// Cache hits are logged at [LoggingLevel.debug].
///
/// Domain errors are returned as [CallToolResult] with [CallToolResult.isError]
/// `true` and a structured JSON payload — exceptions are never swallowed silently.
///
/// See `issues/pub-dev-mcp/06-get-package-tool.md`.
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../cache/memory_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import '../data/pub_client.dart';

/// The input schema for the `get_package` tool.
final _kInputSchema = ObjectSchema(
  required: ['name'],
  properties: {
    'name': Schema.string(description: 'The package name on pub.dev.'),
    'version': Schema.string(
      description:
          'A specific version string (e.g. "1.2.0"). '
          'Omit to fetch the latest published version.',
    ),
  },
);

/// The `get_package` tool definition registered with the MCP server.
final getPackageTool = Tool(
  name: 'get_package',
  description:
      'Get full details for a pub.dev package. '
      'Returns a PackageDetail with scores, SDK constraints, dependencies, '
      'recent versions, and a README excerpt. '
      'Optionally pin a specific version with the version parameter. '
      'Use search_packages first to discover package names.',
  inputSchema: _kInputSchema,
);

/// Handles calls to the `get_package` MCP tool.
///
/// Consults the cache before issuing HTTP requests; stores successful results
/// with [kPackageMetadataTtl]. Logs cache hits at [LoggingLevel.debug] and
/// HTTP requests at [LoggingLevel.info]. Error results are not cached so
/// transient failures can be retried by the next call.
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
  /// Looks up [PackageDetail] in cache, or fetches it from pub.dev.
  /// Returns [CallToolResult.isError] `true` on any domain failure.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final name = (args['name'] as String?) ?? '';
    final version = args['version'] as String?;

    final cacheKey = 'package:$name:${version ?? ''}';

    _log(
      LoggingLevel.info,
      'get_package: name=$name${version != null ? ' version=$version' : ''}',
    );

    final cached = _cache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'get_package: cache hit key=$cacheKey');
      return _success(await cached);
    }

    _log(LoggingLevel.debug, 'get_package: cache miss key=$cacheKey');
    _log(LoggingLevel.info, 'get_package: HTTP request name=$name');

    final result =
        version != null
            ? await _client.getPackageVersion(name, version)
            : await _client.getPackage(name);

    if (result case PubDevSuccess(:final value)) {
      _cache.set(cacheKey, Future.value(value), kPackageMetadataTtl);
      return _success(value);
    }

    return _domainError((result as PubDevFailure<PackageDetail>).error);
  }

  static CallToolResult _success(PackageDetail detail) => CallToolResult(
    content: [TextContent(text: jsonEncode(_detailToJson(detail)))],
  );

  static CallToolResult _domainError(DomainError error) => CallToolResult(
    content: [TextContent(text: error.toJsonString())],
    isError: true,
  );

  static Map<String, Object?> _detailToJson(PackageDetail d) => {
    'name': d.name,
    'version': d.version,
    'description': d.description,
    'verified': d.verified,
    if (d.publishedAt != null) 'publishedAt': d.publishedAt!.toIso8601String(),
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
