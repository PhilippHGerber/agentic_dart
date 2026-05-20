/// Handler for the `search_packages` MCP tool.
///
/// Searches pub.dev by keyword with optional SDK, platform, and sort filters.
/// Returns a `List<PackageSummary>` with computed [PackageSummary.activeMaintenance]
/// and [PackageSummary.daysSinceUpdate] fields.
///
/// Cache key format: `search:<query>:<limit>:<page>:<sdk>:<sort>:<platform>`.
/// Results are cached with a [kSearchResultsTtl] TTL. Cache hits are logged
/// at [LoggingLevel.debug].
///
/// Domain errors are returned as [CallToolResult] with [CallToolResult.isError]
/// `true` and a structured JSON payload — exceptions are never swallowed silently.
///
/// See `issues/pub-dev-mcp/05-server-skeleton-search-packages.md`.
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../cache/memory_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import '../data/pub_client.dart';

/// Well-known error code returned when the caller supplies an invalid input.
const _kInvalidInput = 'invalid_input';

/// Handles calls to the `search_packages` MCP tool.
///
/// Consults `cache` before issuing HTTP requests; stores results with
/// [kSearchResultsTtl]. Logs cache hits at [LoggingLevel.debug] and HTTP
/// requests at [LoggingLevel.info] via `log`.
final class SearchPackagesHandler {
  /// Creates a [SearchPackagesHandler].
  ///
  /// [client] is the pub.dev HTTP gateway. [cache] is the shared TTL store.
  /// [log] receives structured log events at the appropriate [LoggingLevel].
  const SearchPackagesHandler({
    required PubDevClient client,
    required ResponseCache<List<PackageSummary>> cache,
    required void Function(LoggingLevel, Object) log,
  }) : _client = client,
       _cache = cache,
       _log = log;

  final PubDevClient _client;
  final ResponseCache<List<PackageSummary>> _cache;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `search_packages`.
  ///
  /// Validates `limit` against the 20-result cap, consults the cache, and
  /// delegates to [PubDevClient.search]. Returns [CallToolResult.isError] `true`
  /// with a structured JSON payload on any domain failure.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};

    final query = (args['query'] as String?) ?? '';
    final limit = (args['limit'] as int?) ?? 5;
    final page = (args['page'] as int?) ?? 1;
    final sdk = args['sdk'] as String?;
    final sort = (args['sort'] as String?) ?? 'relevance';
    final platform = args['platform'] as String?;

    if (limit > 20) {
      return _domainError(
        const DomainError(
          error: _kInvalidInput,
          message: 'limit must not exceed 20.',
          suggestion: 'Set limit to a value between 1 and 20 and retry.',
        ),
      );
    }

    _log(LoggingLevel.info, 'search_packages: query=$query limit=$limit page=$page');

    final cacheKey = 'search:$query:$limit:$page:${sdk ?? ''}:$sort:${platform ?? ''}';

    final cached = _cache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'search_packages: cache hit key=$cacheKey');
      final summaries = await cached;
      return _success(summaries);
    }

    _log(LoggingLevel.debug, 'search_packages: cache miss key=$cacheKey');

    final future = _client.search(
      query,
      sort: sort,
      sdk: sdk,
      platform: platform,
      page: page,
      limit: limit,
    );

    _cache.set(
      cacheKey,
      future.then(
        (r) => switch (r) {
          PubDevSuccess(:final value) => value,
          PubDevFailure() => <PackageSummary>[],
        },
      ),
      kSearchResultsTtl,
    );

    _log(LoggingLevel.info, 'search_packages: HTTP request query=$query');

    final result = await future;

    return switch (result) {
      PubDevSuccess(:final value) => _success(value),
      PubDevFailure(:final error) => _domainError(error),
    };
  }

  static CallToolResult _success(List<PackageSummary> summaries) => CallToolResult(
    content: [TextContent(text: jsonEncode(_summariesToJson(summaries)))],
  );

  static CallToolResult _domainError(DomainError error) => CallToolResult(
    content: [TextContent(text: error.toJsonString())],
    isError: true,
  );

  static List<Map<String, Object?>> _summariesToJson(List<PackageSummary> summaries) => [
    for (final s in summaries) _summaryToJson(s),
  ];

  static Map<String, Object?> _summaryToJson(PackageSummary s) => {
    'name': s.name,
    'version': s.version,
    'description': s.description,
    'likes': s.likes,
    'pubPoints': s.pubPoints,
    'popularity': s.popularity,
    'verified': s.verified,
    'sdks': s.sdks,
    'platforms': s.platforms,
    'topics': s.topics,
    'isFlutterFavorite': s.isFlutterFavorite,
    'daysSinceUpdate': s.daysSinceUpdate,
    'activeMaintenance': s.activeMaintenance,
    if (s.publisher != null) 'publisher': s.publisher,
    if (s.license != null) 'license': s.license,
  };
}
