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
/// ## Caching
///
/// The dartdoc symbol index is resolved through the shared `apiIndex`
/// [KeyedCache] facade (built by `CacheRegistry`), keyed by `(package,
/// resolvedVersion)` — shared with `browse_api_symbols`, `find_symbols`, and
/// `get_api_diff`, so a warm entry serves all four.
///
/// The symbol doc page is resolved through the shared `symbolDoc` [KeyedCache]
/// facade (built by `CacheRegistry`), keyed by `(package, resolvedVersion,
/// href)`. The version segment prevents a cached response for one version from
/// being silently served for another.
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

import '../cache/cache_registry.dart';
import '../cache/keyed_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import 'tool_response.dart';
import 'version_resolver.dart';

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
/// Resolves the dartdoc symbol index through `apiIndex` and the symbol doc page
/// itself through `symbolDoc` before issuing any HTTP request. Logs at
/// [LoggingLevel.info] via `log`.
final class GetSymbolDocumentationHandler {
  /// Creates a [GetSymbolDocumentationHandler].
  ///
  /// [versionResolver] resolves the Resolved Version, falling back to the
  /// Latest Stable Version when the caller omits one. [apiIndex] is the shared
  /// [KeyedCache] facade (from `CacheRegistry`) that resolves and caches the
  /// dartdoc symbol index by [ApiIndexId] — pass the same instance used by
  /// `browse_api_symbols` to share warm index data. [symbolDoc] is the shared
  /// [KeyedCache] facade that resolves and caches individual symbol
  /// documentation pages by [SymbolDocId]. [log] receives structured log
  /// events at the appropriate [LoggingLevel].
  const GetSymbolDocumentationHandler({
    required VersionResolver versionResolver,
    required KeyedCache<ApiIndexId, List<DartdocSymbol>> apiIndex,
    required KeyedCache<SymbolDocId, String> symbolDoc,
    required void Function(LoggingLevel, Object) log,
  }) : _versionResolver = versionResolver,
       _apiIndex = apiIndex,
       _symbolDoc = symbolDoc,
       _log = log;

  final VersionResolver _versionResolver;
  final KeyedCache<ApiIndexId, List<DartdocSymbol>> _apiIndex;
  final KeyedCache<SymbolDocId, String> _symbolDoc;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `get_symbol_documentation`.
  ///
  /// Resolves the version (via [VersionResolver] when absent), resolves the
  /// `symbol` name to an href via the API index, then fetches
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
    switch (await _versionResolver.resolve(
      package: package,
      supplied: suppliedVersion,
      tool: 'get_symbol_documentation',
    )) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        resolvedVersion = value;
    }

    // ── Step 2: resolve the API index ─────────────────────────────────────────

    final List<DartdocSymbol> symbols;
    switch (await _apiIndex.resolve((name: package, version: resolvedVersion))) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        symbols = value;
    }

    if (symbols.isEmpty) return ToolResponse.error(_kNoDocumentation);

    // ── Step 3: resolve symbol name → href ────────────────────────────────────

    final match = _resolveSymbol(symbols, symbol);

    return switch (match) {
      _NoMatch() => ToolResponse.error(
        DomainError(
          code: DomainErrors.symbolNotFound,
          message: "Symbol '$symbol' was not found in the API index for package '$package'.",
          suggestion:
              'Verify the symbol name is correct. '
              'Use browse_api_symbols to discover available symbol names.',
        ),
      ),
      _AmbiguousMatch(:final alternatives) => ToolResponse.error(
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
    final result = await _symbolDoc.resolve((
      package: package,
      version: resolvedVersion,
      href: href,
    ));
    return switch (result) {
      PubDevSuccess(:final value) => _successResult(value, resolvedVersion),
      PubDevFailure(:final error) => ToolResponse.error(error),
    };
  }

  // ── Static helpers ─────────────────────────────────────────────────────────

  static const _kNoDocumentation = DomainError(
    code: DomainErrors.noDocumentation,
    message: 'No API documentation found for this package.',
    suggestion: 'Verify the package name and that it has dartdoc output on pub.dev.',
  );

  static CallToolResult _successResult(String text, String resolvedVersion) =>
      ToolResponse.ok({'documentation': text}, resolvedVersion: resolvedVersion);
}
