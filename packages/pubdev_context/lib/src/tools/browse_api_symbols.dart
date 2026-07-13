/// Handler for the `browse_api_symbols` MCP tool.
///
/// Searches the dartdoc symbol index (`index.json`) of a pub.dev package for
/// matching API symbols, ranking exact [DartdocSymbol.name] matches before
/// [DartdocSymbol.desc]-only matches. An optional `type` filter is applied
/// after ranking. Results are capped at `limit`.
///
/// When `version` is omitted the handler resolves the latest stable version
/// via [VersionResolver]. Every success response includes `resolvedVersion` as
/// its first JSON key.
///
/// The dartdoc symbol index is resolved through the shared `apiIndex`
/// [KeyedCache] facade (built by `CacheRegistry`), keyed by `(package,
/// resolvedVersion)`. That facade is shared with `find_symbols`,
/// `get_api_diff`, and the symbol-documentation handler, so a warm entry
/// serves all four without a second pub.dev fetch.
///
/// Domain errors:
/// - `NO_DOCUMENTATION`: `index.json` is missing or empty for the package.
/// - `NO_RESULTS`: the query or type filter yields zero matching symbols.
/// - `INVALID_ARGUMENT`: `limit` exceeds 25.
///
/// See `issues/pub-dev-mcp/09-search-api-symbols-tool.md`.
library;

import 'package:dart_mcp/server.dart';

import '../cache/cache_registry.dart';
import '../cache/keyed_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import 'tool_response.dart';
import 'version_resolver.dart';

/// Handles calls to the `browse_api_symbols` MCP tool.
///
/// Resolves the dartdoc symbol index through `apiIndex` before issuing any
/// HTTP request. Logs at [LoggingLevel.info] via `log`.
final class BrowseApiSymbolsHandler {
  /// Creates a [BrowseApiSymbolsHandler].
  ///
  /// [versionResolver] resolves the Resolved Version, falling back to the
  /// Latest Stable Version when the caller omits one. [apiIndex] is the shared
  /// [KeyedCache] facade (from `CacheRegistry`) that resolves and caches the
  /// dartdoc symbol index by [ApiIndexId]. [log] receives structured log
  /// events at the appropriate [LoggingLevel].
  const BrowseApiSymbolsHandler({
    required VersionResolver versionResolver,
    required KeyedCache<ApiIndexId, List<DartdocSymbol>> apiIndex,
    required void Function(LoggingLevel, Object) log,
  }) : _versionResolver = versionResolver,
       _apiIndex = apiIndex,
       _log = log;

  final VersionResolver _versionResolver;
  final KeyedCache<ApiIndexId, List<DartdocSymbol>> _apiIndex;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `browse_api_symbols`.
  ///
  /// Resolves the version (via [VersionResolver] when absent) and resolves the
  /// dartdoc symbol index through `apiIndex`. Exact
  /// [DartdocSymbol.name] matches are ranked before [DartdocSymbol.desc]-only
  /// matches; the optional `type` filter is applied after ranking. Returns
  /// [CallToolResult.isError] `true` with a structured JSON payload on any
  /// domain failure. `limit` is capped at 25 by the tool's input schema.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};

    final package = (args['package'] as String?) ?? '';
    final query = (args['query'] as String?) ?? '';
    final type = args['type'] as String?;
    final limit = (args['limit'] as int?) ?? 10;
    final suppliedVersion = args['version'] as String?;

    _log(
      LoggingLevel.info,
      'browse_api_symbols: package=$package query=$query limit=$limit'
      '${suppliedVersion != null ? ' version=$suppliedVersion' : ''}',
    );

    // ── Resolve version ────────────────────────────────────────────────────────

    final String resolvedVersion;
    switch (await _versionResolver.resolve(
      package: package,
      supplied: suppliedVersion,
      tool: 'browse_api_symbols',
    )) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        resolvedVersion = value;
    }

    // ── Resolve the API index ───────────────────────────────────────────────────

    final result = await _apiIndex.resolve((name: package, version: resolvedVersion));

    return switch (result) {
      PubDevSuccess(:final value) => _buildResponse(value, query, type, limit, resolvedVersion),
      PubDevFailure(:final error) => ToolResponse.error(error),
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
    String resolvedVersion,
  ) {
    if (symbols.isEmpty) return ToolResponse.error(_kNoDocumentation);

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
      return ToolResponse.error(
        const DomainError(
          code: DomainErrors.noResults,
          message: 'No symbols matched the query or type filter.',
          suggestion: 'Try a broader query, remove the type filter, or verify the package name.',
        ),
      );
    }

    return ToolResponse.ok(
      {'symbols': _symbolsToJson(filtered.take(limit).toList())},
      resolvedVersion: resolvedVersion,
    );
  }

  static const _kNoDocumentation = DomainError(
    code: DomainErrors.noDocumentation,
    message: 'No API documentation found for this package.',
    suggestion: 'Verify the package name and that it has dartdoc output on pub.dev.',
  );

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
