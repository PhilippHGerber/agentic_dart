/// Handler for the `search_packages` MCP tool.
///
/// Searches pub.dev by keyword with optional SDK, platform, and sort filters.
/// Returns a `List<PackageSummary>` with computed [PackageSummary.activeMaintenance]
/// and [PackageSummary.daysSinceUpdate] fields.
///
/// Results are resolved through the shared `searchResults` [KeyedCache] facade
/// (from `CacheRegistry`), keyed by the full query tuple ([SearchResultsId]) —
/// the cache-key format, TTL, and skip-on-failure policy all live there. The
/// same facade backs the server's `{name}` autocomplete.
///
/// Domain errors are returned as [CallToolResult] with [CallToolResult.isError]
/// `true` and a structured JSON payload — exceptions are never swallowed silently.
///
/// See `issues/pub-dev-mcp/05-server-skeleton-search-packages.md`.
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../cache/cache_registry.dart';
import '../cache/keyed_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';

/// Well-known error code returned when the caller supplies an invalid input.
const String _kInvalidInput = DomainErrors.invalidArgument;

/// Handles calls to the `search_packages` MCP tool.
///
/// Resolves through `searchResults` before issuing any HTTP request. Logs at
/// [LoggingLevel.info] via `log`.
final class SearchPackagesHandler {
  /// Creates a [SearchPackagesHandler].
  ///
  /// [searchResults] is the shared [KeyedCache] facade (from `CacheRegistry`)
  /// that resolves and caches a search-results page by [SearchResultsId].
  /// [log] receives structured log events at the appropriate [LoggingLevel].
  const SearchPackagesHandler({
    required KeyedCache<SearchResultsId, List<PackageSummary>> searchResults,
    required void Function(LoggingLevel, Object) log,
  }) : _searchResults = searchResults,
       _log = log;

  final KeyedCache<SearchResultsId, List<PackageSummary>> _searchResults;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `search_packages`.
  ///
  /// Validates `limit` against the 20-result cap, then resolves the page
  /// through `searchResults`. Returns [CallToolResult.isError] `true` with a
  /// structured JSON payload on any domain failure.
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
          code: _kInvalidInput,
          message: 'limit must not exceed 20.',
          suggestion: 'Set limit to a value between 1 and 20 and retry.',
        ),
      );
    }

    _log(LoggingLevel.info, 'search_packages: query=$query limit=$limit page=$page');

    final result = await _searchResults.resolve((
      query: query,
      limit: limit,
      page: page,
      sdk: sdk,
      sort: sort,
      platform: platform,
    ));

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
