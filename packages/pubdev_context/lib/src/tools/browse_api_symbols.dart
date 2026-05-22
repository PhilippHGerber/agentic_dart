/// Handler for the `browse_api_symbols` MCP tool.
///
/// Searches the dartdoc symbol index (`index.json`) of a pub.dev package for
/// matching API symbols, ranking exact [DartdocSymbol.name] matches before
/// [DartdocSymbol.desc]-only matches. An optional `type` filter is applied
/// after ranking. Results are capped at `limit`.
///
/// Cache key format: `api_index:<package>` (see [kApiIndexCachePrefix]).
/// The API index is cached with a [kApiDocsTtl] TTL and the cache key is
/// intentionally shared with the package resource handler so that both modules
/// warm each other's cache. Cache hits are logged at [LoggingLevel.debug].
///
/// Domain errors:
/// - `no_documentation`: `index.json` is missing or empty for the package.
/// - `no_results`: the query or type filter yields zero matching symbols.
/// - `invalid_input`: `limit` exceeds 25.
///
/// See `issues/pub-dev-mcp/09-search-api-symbols-tool.md`.
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../cache/memory_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import '../data/pub_client.dart';

/// Cache-key prefix used by both [BrowseApiSymbolsHandler] and the package
/// resource handler (issue 11) to share the dartdoc symbol index cache.
///
/// Full key format: `$kApiIndexCachePrefix:<packageName>`.
const kApiIndexCachePrefix = 'api_index';

/// Handles calls to the `browse_api_symbols` MCP tool.
///
/// Consults `cache` before issuing HTTP requests; stores results with
/// [kApiDocsTtl]. Logs cache hits at [LoggingLevel.debug] and HTTP requests
/// at [LoggingLevel.info] via `log`.
final class BrowseApiSymbolsHandler {
  /// Creates a [BrowseApiSymbolsHandler].
  ///
  /// [client] is the pub.dev HTTP gateway. [cache] is the shared TTL store
  /// for dartdoc symbol indexes; pass the same instance to the package resource
  /// handler so both modules warm each other's cache. [log] receives structured
  /// log events at the appropriate [LoggingLevel].
  const BrowseApiSymbolsHandler({
    required PubDevClient client,
    required ResponseCache<List<DartdocSymbol>> cache,
    required void Function(LoggingLevel, Object) log,
  }) : _client = client,
       _cache = cache,
       _log = log;

  final PubDevClient _client;
  final ResponseCache<List<DartdocSymbol>> _cache;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `browse_api_symbols`.
  ///
  /// Validates `limit` against the 25-result cap, consults the cache, and
  /// delegates to [PubDevClient.getApiIndex]. Exact [DartdocSymbol.name]
  /// matches are ranked before [DartdocSymbol.desc]-only matches; the optional
  /// `type` filter is applied after ranking. Returns [CallToolResult.isError]
  /// `true` with a structured JSON payload on any domain failure.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};

    final package = (args['package'] as String?) ?? '';
    final query = (args['query'] as String?) ?? '';
    final type = args['type'] as String?;
    final limit = (args['limit'] as int?) ?? 10;

    if (limit > 25) {
      return _domainError(
        const DomainError(
          error: DomainErrors.invalidInput,
          message: 'limit must not exceed 25.',
          suggestion: 'Set limit to a value between 1 and 25 and retry.',
        ),
      );
    }

    _log(LoggingLevel.info, 'browse_api_symbols: package=$package query=$query limit=$limit');

    final cacheKey = '$kApiIndexCachePrefix:$package';

    final cached = _cache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'browse_api_symbols: cache hit key=$cacheKey');
      final symbols = await cached;
      return _buildResponse(symbols, query, type, limit);
    }

    _log(LoggingLevel.debug, 'browse_api_symbols: cache miss key=$cacheKey');

    final future = _client.getApiIndex(package);

    _cache.set(
      cacheKey,
      future.then(
        (r) => switch (r) {
          PubDevSuccess(:final value) => value,
          PubDevFailure() => <DartdocSymbol>[],
        },
      ),
      kApiDocsTtl,
    );

    _log(LoggingLevel.info, 'browse_api_symbols: HTTP request package=$package');

    final result = await future;

    return switch (result) {
      PubDevSuccess(:final value) => _buildResponse(value, query, type, limit),
      PubDevFailure(:final error) when error.error == DomainErrors.packageNotFound => _domainError(
        _kNoDocumentation,
      ),
      PubDevFailure(:final error) => _domainError(error),
    };
  }

  /// Ranks and filters [symbols], then serialises the result.
  ///
  /// Returns `no_documentation` when [symbols] is empty. Returns `no_results`
  /// when the ranked and filtered list is empty.
  CallToolResult _buildResponse(
    List<DartdocSymbol> symbols,
    String query,
    String? type,
    int limit,
  ) {
    if (symbols.isEmpty) return _domainError(_kNoDocumentation);

    final queryLower = query.toLowerCase();
    final nameMatches = <DartdocSymbol>[];
    final descMatches = <DartdocSymbol>[];

    for (final symbol in symbols) {
      if (symbol.name.toLowerCase().contains(queryLower)) {
        nameMatches.add(symbol);
      } else if (symbol.desc.toLowerCase().contains(queryLower)) {
        descMatches.add(symbol);
      }
    }

    final ranked = [...nameMatches, ...descMatches];
    final filtered = type != null ? ranked.where((s) => s.type == type).toList() : ranked;

    if (filtered.isEmpty) {
      return _domainError(
        const DomainError(
          error: 'no_results',
          message: 'No symbols matched the query or type filter.',
          suggestion: 'Try a broader query, remove the type filter, or verify the package name.',
        ),
      );
    }

    return CallToolResult(
      content: [
        TextContent(text: jsonEncode(_symbolsToJson(filtered.take(limit).toList()))),
      ],
    );
  }

  static const _kNoDocumentation = DomainError(
    error: DomainErrors.noDocumentation,
    message: 'No API documentation found for this package.',
    suggestion: 'Verify the package name and that it has dartdoc output on pub.dev.',
  );

  static CallToolResult _domainError(DomainError error) =>
      CallToolResult(content: [TextContent(text: error.toJsonString())], isError: true);

  static List<Map<String, Object?>> _symbolsToJson(List<DartdocSymbol> symbols) => [
    for (final s in symbols) _symbolToJson(s),
  ];

  static Map<String, Object?> _symbolToJson(DartdocSymbol s) => {
    'name': s.name,
    'qualifiedName': s.qualifiedName,
    'href': s.href,
    'type': s.type,
    if (s.desc.isNotEmpty) 'desc': s.desc,
  };
}
