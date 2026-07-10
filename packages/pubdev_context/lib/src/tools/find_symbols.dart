/// Handler for the `find_symbols` MCP tool.
///
/// Searches a package's public API for symbols matching a query, backed by the
/// same dartdoc `index.json` as `browse_api_symbols`. The two tools share the
/// [kApiIndexCachePrefix] cache key, so a warm index serves both without an
/// extra download.
///
/// Matching is a case-insensitive substring match against [DartdocSymbol.name],
/// falling back to a token-based fuzzy match against [DartdocSymbol.desc] for
/// symbols whose name does not match. Name matches always rank before
/// description-only matches. Results are capped at [_kMaxResults]; when more
/// matches exist, `hasMore: true` is included in the response.
///
/// When `version` is omitted the handler resolves the latest stable version via
/// [PubDevClient.resolveLatestStable]. Every success response includes
/// `resolvedVersion` as its first JSON key.
///
/// Domain errors:
/// - `INVALID_ARGUMENT`: `package` or `query` is missing. The missing-`package`
///   error carries a `suggestedNextStep` pointing at `search_packages`.
/// - `NO_DOCUMENTATION`: `index.json` is missing or empty for the package.
///
/// See `issues/pubdev-context-v1/09-find-symbols.md`.
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../cache/memory_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import '../data/pub_client.dart';
import 'browse_api_symbols.dart' show BrowseApiSymbolsHandler, kApiIndexCachePrefix;

/// Maximum number of symbol matches returned in a single response.
const _kMaxResults = 20;

/// Handles calls to the `find_symbols` MCP tool.
///
/// Consults `cache` before issuing HTTP requests; stores results with
/// [kApiDocsTtl] under the [kApiIndexCachePrefix]-prefixed key shared with
/// [BrowseApiSymbolsHandler]. Logs cache activity at [LoggingLevel.debug] and
/// HTTP requests at [LoggingLevel.info] via `log`.
final class FindSymbolsHandler {
  /// Creates a [FindSymbolsHandler].
  ///
  /// [client] is the pub.dev HTTP gateway. [cache] is the shared TTL store for
  /// dartdoc symbol indexes; pass the same instance used by
  /// [BrowseApiSymbolsHandler] so both tools warm each other's cache. [log]
  /// receives structured log events at the appropriate [LoggingLevel].
  const FindSymbolsHandler({
    required PubDevClient client,
    required ResponseCache<List<DartdocSymbol>> cache,
    required void Function(LoggingLevel, Object) log,
  }) : _client = client,
       _cache = cache,
       _log = log;

  final PubDevClient _client;
  final ResponseCache<List<DartdocSymbol>> _cache;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `find_symbols`.
  ///
  /// Validates that both `package` and `query` are present, resolves the
  /// version (via [PubDevClient.resolveLatestStable] when absent), consults the
  /// cache, and delegates to [PubDevClient.getApiIndex]. Returns
  /// [CallToolResult.isError] `true` with a structured JSON payload on any
  /// domain failure.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};

    final package = (args['package'] as String?) ?? '';
    final query = (args['query'] as String?) ?? '';
    final suppliedVersion = args['version'] as String?;

    if (package.isEmpty) {
      return _domainError(
        const DomainError(
          code: DomainErrors.invalidArgument,
          message: 'The package argument is required.',
          suggestion: 'Provide a pub.dev package name. Use search_packages to find one.',
          suggestedNextStep: {'tool': 'search_packages'},
        ),
      );
    }

    if (query.isEmpty) {
      return _domainError(
        const DomainError(
          code: DomainErrors.invalidArgument,
          message: 'The query argument is required.',
          suggestion: 'Provide a symbol name or keyword to search for.',
        ),
      );
    }

    _log(
      LoggingLevel.info,
      'find_symbols: package=$package query=$query'
      '${suppliedVersion != null ? ' version=$suppliedVersion' : ''}',
    );

    // ── Resolve version ────────────────────────────────────────────────────────

    final String resolvedVersion;
    if (suppliedVersion != null) {
      resolvedVersion = suppliedVersion;
    } else {
      _log(LoggingLevel.info, 'find_symbols: resolving latest stable version for $package');
      final versionResult = await _client.resolveLatestStable(package);
      if (versionResult case PubDevFailure(:final error)) return _domainError(error);
      resolvedVersion = (versionResult as PubDevSuccess<String>).value;
      _log(LoggingLevel.debug, 'find_symbols: resolved version=$resolvedVersion');
    }

    // ── Cache lookup ───────────────────────────────────────────────────────────

    final cacheKey = '$kApiIndexCachePrefix:$package:$resolvedVersion';

    final cached = _cache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'find_symbols: cache hit key=$cacheKey');
      final symbols = await cached;
      return _buildResponse(symbols, package, query, resolvedVersion);
    }

    _log(LoggingLevel.debug, 'find_symbols: cache miss key=$cacheKey');

    final future = _client.getApiIndex(package, version: resolvedVersion);

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

    _log(LoggingLevel.info, 'find_symbols: HTTP request package=$package');

    final result = await future;

    return switch (result) {
      PubDevSuccess(:final value) => _buildResponse(value, package, query, resolvedVersion),
      PubDevFailure(:final error) when error.code == DomainErrors.packageNotFound => _domainError(
        _kNoDocumentation,
      ),
      PubDevFailure(:final error) => _domainError(error),
    };
  }

  /// Matches, ranks, caps and serialises [symbols].
  ///
  /// Returns `no_documentation` when [symbols] is empty. Name substring matches
  /// rank before description fuzzy matches. When more than [_kMaxResults]
  /// matches exist the response carries `hasMore: true`.
  CallToolResult _buildResponse(
    List<DartdocSymbol> symbols,
    String package,
    String query,
    String resolvedVersion,
  ) {
    if (symbols.isEmpty) return _domainError(_kNoDocumentation);

    final queryLower = query.toLowerCase();
    final queryTokens = queryLower.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();

    final nameMatches = <DartdocSymbol>[];
    final descMatches = <DartdocSymbol>[];

    for (final symbol in symbols) {
      if (symbol.name.toLowerCase().contains(queryLower)) {
        nameMatches.add(symbol);
      } else if (_descMatches(symbol.desc, queryTokens)) {
        descMatches.add(symbol);
      }
    }

    final ranked = [...nameMatches, ...descMatches];
    final hasMore = ranked.length > _kMaxResults;

    return CallToolResult(
      content: [
        TextContent(
          text: jsonEncode({
            'resolvedVersion': resolvedVersion,
            if (hasMore) 'hasMore': true,
            'symbols': [
              for (final s in ranked.take(_kMaxResults)) _symbolToJson(s, package),
            ],
          }),
        ),
      ],
    );
  }

  /// Fuzzy description match: every query token must appear as a substring of
  /// the lower-cased [desc]. For single-token queries this is a plain substring
  /// match; multi-token queries match regardless of token order.
  static bool _descMatches(String desc, List<String> queryTokens) {
    if (queryTokens.isEmpty) return false;
    final descLower = desc.toLowerCase();
    return queryTokens.every(descLower.contains);
  }

  /// The dartdoc library segment a symbol belongs to, derived from the leading
  /// dotted component of [DartdocSymbol.qualifiedName] (falling back to the
  /// first `href` path segment).
  static String _librarySegment(DartdocSymbol s) {
    final qn = s.qualifiedName;
    if (qn.isNotEmpty) {
      final dot = qn.indexOf('.');
      return dot == -1 ? qn : qn.substring(0, dot);
    }
    final href = s.href;
    final slash = href.indexOf('/');
    return slash == -1 ? href : href.substring(0, slash);
  }

  static Map<String, Object?> _symbolToJson(DartdocSymbol s, String package) => {
    'name': s.name,
    'qualifiedName': s.qualifiedName,
    'kind': s.type,
    'library': 'package:$package/${_librarySegment(s)}.dart',
    'enclosedBy': s.enclosedBy,
    'description': s.desc,
    'href': s.href,
  };

  static const _kNoDocumentation = DomainError(
    code: DomainErrors.noDocumentation,
    message: 'No API documentation found for this package.',
    suggestion: 'Verify the package name and that it has dartdoc output on pub.dev.',
  );

  static CallToolResult _domainError(DomainError error) =>
      CallToolResult(content: [TextContent(text: error.toJsonString())], isError: true);
}
