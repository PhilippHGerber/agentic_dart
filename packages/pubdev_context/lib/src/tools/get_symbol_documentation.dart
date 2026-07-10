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
/// API index: `api_index:<package>:<resolvedVersion>` — the version segment is
/// always a concrete semver (latest-stable is resolved before the key is built),
/// shared with `browse_api_symbols` (see [kApiIndexCachePrefix]).
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

import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../cache/memory_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import '../data/pub_client.dart';
import 'browse_api_symbols.dart';

/// Cache-key prefix for symbol documentation entries.
///
/// Full key format: `$kSymbolDocCachePrefix:<package>:<version>:<href>`.
/// The version segment is always a concrete semver (e.g. `"1.2.0"`) — the
/// latest-stable version is resolved before the key is built — so requests for
/// different versions never reuse each other's cached docs.
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
  /// Resolves the version (via [PubDevClient.resolveLatestStable] when absent),
  /// resolves the `symbol` name to an href via the API index, then fetches
  /// and returns the dartdoc page content wrapped in a JSON object with
  /// `resolvedVersion` as the first key. Returns [CallToolResult.isError]
  /// `true` with a structured JSON payload on any domain failure.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};

    final package = (args['package'] as String?) ?? '';
    final symbol = (args['symbol'] as String?) ?? '';
    final suppliedVersion = args['version'] as String?;

    _log(
      LoggingLevel.info,
      'get_symbol_documentation: package=$package symbol=$symbol'
      '${suppliedVersion != null ? ' version=$suppliedVersion' : ''}',
    );

    // ── Step 1: resolve version ────────────────────────────────────────────────

    final String resolvedVersion;
    if (suppliedVersion != null) {
      resolvedVersion = suppliedVersion;
    } else {
      _log(
        LoggingLevel.info,
        'get_symbol_documentation: resolving latest stable version for $package',
      );
      switch (await _client.resolveLatestStable(package)) {
        case PubDevFailure(:final error):
          return _domainError(error);
        case PubDevSuccess(:final value):
          resolvedVersion = value;
      }
      _log(LoggingLevel.debug, 'get_symbol_documentation: resolved version=$resolvedVersion');
    }

    // ── Step 2: fetch (or warm) the API index ─────────────────────────────────

    final indexCacheKey = '$kApiIndexCachePrefix:$package:$resolvedVersion';

    List<DartdocSymbol> symbols;

    final cachedIndex = _apiIndexCache.get(indexCacheKey);
    if (cachedIndex != null) {
      _log(LoggingLevel.debug, 'get_symbol_documentation: index cache hit key=$indexCacheKey');
      symbols = await cachedIndex;
    } else {
      _log(LoggingLevel.debug, 'get_symbol_documentation: index cache miss key=$indexCacheKey');
      _log(LoggingLevel.info, 'get_symbol_documentation: index HTTP request package=$package');

      switch (await _client.getApiIndex(package, version: resolvedVersion)) {
        case PubDevFailure(:final error) when error.code == DomainErrors.packageNotFound:
          return _domainError(_kNoDocumentation);
        case PubDevFailure(:final error):
          return _domainError(error);
        case PubDevSuccess(:final value):
          symbols = value;
      }

      // Populate the cache only after a successful fetch. Storing a
      // failure-mapped empty list would poison the cache: every subsequent
      // call within the TTL window would return `no_documentation` without
      // retrying, letting a single transient error (429/503/network) outlive
      // the outage itself.
      _apiIndexCache.set(indexCacheKey, Future.value(symbols), kApiDocsTtl);
    }

    if (symbols.isEmpty) return _domainError(_kNoDocumentation);

    // ── Step 3: resolve symbol name → href ────────────────────────────────────

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
      _SingleMatch(:final href) => await _fetchDoc(package, href, resolvedVersion),
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

  Future<CallToolResult> _fetchDoc(String package, String href, String resolvedVersion) async {
    final cacheKey = '$kSymbolDocCachePrefix:$package:$resolvedVersion:$href';

    final cached = _cache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'get_symbol_documentation: doc cache hit key=$cacheKey');
      final text = await cached;
      if (text.isEmpty) return _domainError(_kSymbolNotFound);
      return _successResult(text, resolvedVersion);
    }

    _log(LoggingLevel.debug, 'get_symbol_documentation: doc cache miss key=$cacheKey');
    _log(
      LoggingLevel.info,
      'get_symbol_documentation: doc HTTP request package=$package href=$href',
    );

    final String text;
    switch (await _client.getSymbolDoc(package, href, version: resolvedVersion)) {
      case PubDevFailure(:final error):
        return _domainError(error);
      case PubDevSuccess(:final value):
        text = value;
    }
    // Cache only after a successful fetch. Storing a failure-mapped empty
    // string would poison the cache: every subsequent call within the TTL
    // window would return `symbol_not_found` without retrying, letting a
    // single transient error (429/503/network) outlive the outage itself.
    _cache.set(cacheKey, Future.value(text), kSymbolDocTtl);
    return _successResult(text, resolvedVersion);
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

  static CallToolResult _successResult(String text, String resolvedVersion) => CallToolResult(
    content: [
      TextContent(
        text: jsonEncode({'resolvedVersion': resolvedVersion, 'documentation': text}),
      ),
    ],
  );

  static CallToolResult _domainError(DomainError error) =>
      CallToolResult(content: [TextContent(text: error.toJsonString())], isError: true);
}
