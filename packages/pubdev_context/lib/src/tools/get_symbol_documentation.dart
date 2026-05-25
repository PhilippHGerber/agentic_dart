/// Handler for the `get_symbol_documentation` MCP tool.
///
/// Fetches the full dartdoc page for a specific API symbol and returns its
/// content as plain text. The `symbol` input is a human-readable name
/// (e.g. `"Client"`, `"Client.send"`, or a full `qualifiedName` such as
/// `"http.Client"`) — this handler resolves it to an href internally using
/// the three-pass symbol resolution strategy before fetching the dartdoc page.
///
/// ## Symbol resolution — three-pass strategy
///
/// **Pass 0 — exact `qualifiedName` match:** check for entries where
/// `qualifiedName == symbol`. This is the primary retry path after an
/// `AMBIGUOUS_SYMBOL` error: callers pass a value from the returned
/// `error.details.candidates` array and the match is always unambiguous.
///
/// **Pass 1 — exact `name` match:** scan the API index for entries where
/// `name == symbol`. If exactly one match, use it. If zero matches, proceed
/// to pass 2.
///
/// **Pass 2 — `qualifiedName` suffix match:** strip the library prefix from
/// each entry's `qualifiedName` (everything up to and including the first `.`)
/// and check whether the remainder equals the agent's input. Example: agent
/// input `"Client.send"` matches `"http.Client.send"` after stripping `"http."`.
///
/// **Disambiguation:** when multiple matches survive pass 1 or pass 2, the
/// class-level entry (`type == "class"`) is preferred. If exactly one class
/// entry exists, it is used. If multiple class entries exist, or no class
/// entry exists and multiple matches remain, a [DomainErrors.ambiguousSymbol]
/// error is returned with `error.details.candidates` listing `qualifiedName`
/// values.
///
/// ## Cache keys
///
/// API index: `api_index:<package>` for latest, `api_index:<package>:<version>`
/// for pinned versions (see [kApiIndexCachePrefix]).
///
/// Symbol doc: `symbol_doc:<package>:<version>:<href>` (see [kSymbolDocCachePrefix]).
/// Results are cached with a [kSymbolDocTtl] TTL. The version segment prevents
/// a cached response for one version from being silently served for another.
///
/// ## Domain errors
///
/// - `NO_DOCUMENTATION`: the package has no dartdoc output.
/// - `SYMBOL_NOT_FOUND`: the symbol name could not be resolved, or the resolved
///   href returns HTTP 404.
/// - `AMBIGUOUS_SYMBOL`: the symbol name matches multiple entries;
///   `error.details.candidates` lists `qualifiedName` values. Retry with any.
///
/// See issues #28, #32, #33.
library;

import 'package:dart_mcp/server.dart';

import '../cache/memory_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import '../data/pub_client.dart';
import 'browse_api_symbols.dart';

/// Cache-key prefix for symbol documentation entries.
///
/// Full key format: `$kSymbolDocCachePrefix:<package>:<version>:<href>`.
/// The version segment (e.g. `"latest"` or `"1.2.0"`) ensures that pinned-
/// version requests never reuse docs cached for a different version.
const kSymbolDocCachePrefix = 'symbol_doc';

// ─── Internal resolution result types ─────────────────────────────────────────

sealed class _SymbolMatch {}

final class _SingleMatch extends _SymbolMatch {
  _SingleMatch(this.href);
  final String href;
}

final class _AmbiguousMatch extends _SymbolMatch {
  _AmbiguousMatch(this.alternatives);
  final List<String> alternatives;
}

final class _NoMatch extends _SymbolMatch {}

// ─── Handler ──────────────────────────────────────────────────────────────────

/// Handles calls to the `get_symbol_documentation` MCP tool.
///
/// Consults `apiIndexCache` and `cache` before issuing HTTP requests. Logs
/// cache hits at [LoggingLevel.debug] and HTTP requests at [LoggingLevel.info]
/// via `log`.
final class GetSymbolDocumentationHandler {
  /// Creates a [GetSymbolDocumentationHandler].
  ///
  /// [client] is the pub.dev HTTP gateway.
  /// [cache] is the TTL store for symbol documentation pages.
  /// [apiIndexCache] is the shared TTL store for dartdoc symbol indexes — pass
  /// the same instance as [BrowseApiSymbolsHandler] to share warm index data.
  /// [log] receives structured log events at the appropriate [LoggingLevel].
  const GetSymbolDocumentationHandler({
    required PubDevClient client,
    required ResponseCache<String> cache,
    required ResponseCache<List<DartdocSymbol>> apiIndexCache,
    required void Function(LoggingLevel, Object) log,
  }) : _client = client,
       _cache = cache,
       _apiIndexCache = apiIndexCache,
       _log = log;

  final PubDevClient _client;
  final ResponseCache<String> _cache;
  final ResponseCache<List<DartdocSymbol>> _apiIndexCache;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `get_symbol_documentation`.
  ///
  /// Resolves the `symbol` name to an href via the API index, then fetches
  /// and returns the dartdoc page content. Returns [CallToolResult.isError]
  /// `true` with a structured JSON payload on any domain failure.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};

    final package = (args['package'] as String?) ?? '';
    final symbol = (args['symbol'] as String?) ?? '';
    final version = args['version'] as String?;
    final effectiveVersion = version ?? 'latest';

    _log(
      LoggingLevel.info,
      'get_symbol_documentation: package=$package symbol=$symbol version=$effectiveVersion',
    );

    // ── Step 1: fetch (or warm) the API index ─────────────────────────────────

    final indexCacheKey = version == null
        ? '$kApiIndexCachePrefix:$package'
        : '$kApiIndexCachePrefix:$package:$version';

    List<DartdocSymbol> symbols;

    final cachedIndex = _apiIndexCache.get(indexCacheKey);
    if (cachedIndex != null) {
      _log(LoggingLevel.debug, 'get_symbol_documentation: index cache hit key=$indexCacheKey');
      symbols = await cachedIndex;
    } else {
      _log(LoggingLevel.debug, 'get_symbol_documentation: index cache miss key=$indexCacheKey');
      final indexFuture = _client.getApiIndex(package, version: effectiveVersion);

      _apiIndexCache.set(
        indexCacheKey,
        indexFuture.then(
          (r) => switch (r) {
            PubDevSuccess(:final value) => value,
            PubDevFailure() => <DartdocSymbol>[],
          },
        ),
        kApiDocsTtl,
      );

      _log(LoggingLevel.info, 'get_symbol_documentation: index HTTP request package=$package');

      final indexResult = await indexFuture;
      if (indexResult case PubDevFailure(
        :final error,
      ) when error.code == DomainErrors.packageNotFound) {
        return _domainError(_kNoDocumentation);
      }
      if (indexResult case PubDevFailure(:final error)) return _domainError(error);
      symbols = (indexResult as PubDevSuccess<List<DartdocSymbol>>).value;
    }

    if (symbols.isEmpty) return _domainError(_kNoDocumentation);

    // ── Step 2: resolve symbol name → href ────────────────────────────────────

    final match = _resolveSymbol(symbols, symbol);

    return switch (match) {
      _NoMatch() => _domainError(
        DomainError(
          code: DomainErrors.symbolNotFound,
          message: "Symbol '$symbol' was not found in the API index for package '$package'.",
          suggestion:
              'Verify the symbol name is correct. '
              'Use browse_api_symbols to discover available symbol names.',
        ),
      ),
      _AmbiguousMatch(:final alternatives) => _domainError(
        DomainError(
          code: DomainErrors.ambiguousSymbol,
          message: "Symbol '$symbol' is ambiguous — ${alternatives.length} candidates were found.",
          suggestion:
              'Retry with a more qualified name from the candidates list '
              '(e.g. use the qualifiedName directly).',
          details: {'candidates': alternatives},
        ),
      ),
      _SingleMatch(:final href) => await _fetchDoc(package, href, effectiveVersion),
    };
  }

  // ── Symbol resolution ──────────────────────────────────────────────────────

  /// Resolves [symbol] against [symbols] using a three-pass strategy.
  ///
  /// **Pass 0** — exact [DartdocSymbol.qualifiedName] match. This is the
  /// primary retry path after an `AMBIGUOUS_SYMBOL` error: callers pass a
  /// value from `error.details.candidates` and the match is always unambiguous.
  ///
  /// **Pass 1** — exact [DartdocSymbol.name] match.
  ///
  /// **Pass 2** — [DartdocSymbol.qualifiedName] suffix match (library prefix
  /// stripped up to and including the first `.`).
  ///
  /// Disambiguation: class entries are preferred when multiple matches remain.
  static _SymbolMatch _resolveSymbol(List<DartdocSymbol> symbols, String symbol) {
    // Pass 0: exact qualifiedName match — unambiguous retry path.
    final qnMatches = symbols.where((s) => s.qualifiedName == symbol).toList();
    if (qnMatches.length == 1) return _SingleMatch(qnMatches.first.href);
    if (qnMatches.isNotEmpty) return _disambiguate(qnMatches);

    // Pass 1: exact name match.
    final nameMatches = symbols.where((s) => s.name == symbol).toList();
    if (nameMatches.length == 1) return _SingleMatch(nameMatches.first.href);
    if (nameMatches.isNotEmpty) return _disambiguate(nameMatches);

    // Pass 2: qualifiedName suffix match (strip library prefix).
    final suffixMatches = symbols.where((s) {
      final dot = s.qualifiedName.indexOf('.');
      if (dot == -1) return false;
      return s.qualifiedName.substring(dot + 1) == symbol;
    }).toList();

    return _disambiguate(suffixMatches);
  }

  /// Selects a single match from [candidates] or reports ambiguity.
  ///
  /// If [candidates] is empty, returns [_NoMatch].
  /// If [candidates] has exactly one entry, returns [_SingleMatch].
  /// Otherwise, prefers the sole class-level entry — or reports
  /// [_AmbiguousMatch] when none or multiple class entries exist.
  static _SymbolMatch _disambiguate(List<DartdocSymbol> candidates) {
    if (candidates.isEmpty) return _NoMatch();
    if (candidates.length == 1) return _SingleMatch(candidates.first.href);

    final classEntries = candidates.where((s) => s.type == 'class').toList();
    if (classEntries.length == 1) return _SingleMatch(classEntries.first.href);

    // Multiple class entries, or no class entry with multiple matches.
    return _AmbiguousMatch(candidates.map((s) => s.qualifiedName).toList());
  }

  // ── Symbol doc fetch ───────────────────────────────────────────────────────

  Future<CallToolResult> _fetchDoc(String package, String href, String version) async {
    final cacheKey = '$kSymbolDocCachePrefix:$package:$version:$href';

    final cached = _cache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'get_symbol_documentation: doc cache hit key=$cacheKey');
      final text = await cached;
      if (text.isEmpty) return _domainError(_kSymbolNotFound);
      return _successResult(text);
    }

    _log(LoggingLevel.debug, 'get_symbol_documentation: doc cache miss key=$cacheKey');

    final future = _client.getSymbolDoc(package, href, version: version);
    _cache.set(
      cacheKey,
      future.then(
        (r) => switch (r) {
          PubDevSuccess(:final value) => value,
          PubDevFailure() => '',
        },
      ),
      kSymbolDocTtl,
    );

    _log(
      LoggingLevel.info,
      'get_symbol_documentation: doc HTTP request package=$package href=$href',
    );

    final result = await future;
    return switch (result) {
      PubDevSuccess(:final value) => _successResult(value),
      PubDevFailure(:final error) => _domainError(error),
    };
  }

  // ── Static helpers ─────────────────────────────────────────────────────────

  static const _kSymbolNotFound = DomainError(
    code: DomainErrors.symbolNotFound,
    message: 'Symbol documentation page not found.',
    suggestion: 'Verify the symbol name is correct and the package has dartdoc output.',
  );

  static const _kNoDocumentation = DomainError(
    code: DomainErrors.noDocumentation,
    message: 'No API documentation found for this package.',
    suggestion: 'Verify the package name and that it has dartdoc output on pub.dev.',
  );

  static CallToolResult _successResult(String text) =>
      CallToolResult(content: [TextContent(text: text)]);

  static CallToolResult _domainError(DomainError error) =>
      CallToolResult(content: [TextContent(text: error.toJsonString())], isError: true);
}
