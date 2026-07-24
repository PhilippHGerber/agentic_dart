/// Handler for the `get_api_diff` MCP tool.
///
/// Computes the public-API difference between two explicit versions of a
/// package by downloading and diffing their dartdoc `index.json` artifacts.
/// The result is two sets — `added` and `removed` — each bucketed into
/// `libraries`, `classes`, `methods`, and `fields`.
///
/// The diff is purely set-membership by [DartdocSymbol.qualifiedName]: a symbol
/// present in `toVersion` but not `fromVersion` is *added*; one present in
/// `fromVersion` but not `toVersion` is *removed*. Structural changes to a
/// symbol that exists in both versions (renamed parameters, changed
/// nullability, altered return types) are invisible to this default,
/// dartdoc-index-only comparison — that's what `includeSignatureChanges`
/// closes (see below).
///
/// Both `fromVersion` and `toVersion` are required; there is no latest-stable
/// resolution and no `resolvedVersion` field (there is no single resolved
/// version). Omitting either version returns `INVALID_ARGUMENT`.
///
/// When either version's `index.json` is unavailable (missing or empty),
/// the handler hard-fails with `DOCUMENTATION_NOT_FOUND` and a
/// `suggestedNextStep` pointing the LLM at `browse_api_symbols` for the
/// offending version as a manual workaround.
///
/// Both indexes are resolved through the shared `apiIndex` [KeyedCache]
/// facade, so this tool warms — and is warmed by — `browse_api_symbols`,
/// `find_symbols`, and the symbol-documentation handler.
///
/// ## `includeSignatureChanges` (opt-in, `symbol`-scoped)
///
/// Passing `includeSignatureChanges: true` together with a `symbol` compares
/// that one declaration's signature across both versions and adds a
/// top-level `signatureChange: {qualifiedName, changed, before, after}` to the
/// response. There is no whole-package structural scan — `symbol` is
/// required whenever `includeSignatureChanges` is `true` (`INVALID_ARGUMENT`
/// otherwise), so the default call's cost profile (no tarball downloads)
/// never changes: only an opted-in, symbol-scoped call downloads the two
/// package tarballs (via the shared `AstAccess`) needed to parse and compare
/// one declaration.
///
/// `symbol` is resolved against each version's dartdoc index using the same
/// three-pass strategy as `get_symbol_documentation` (see
/// `resolveDartdocSymbol`). If `symbol` isn't present in *both* versions —
/// it was actually added or removed rather than persisting — the call fails
/// with `SYMBOL_NOT_FOUND` rather than returning a soft "not comparable"
/// result; the `added`/`removed` buckets in the same response already show
/// that case. `before`/`after` are AST-reconstructed (via
/// `renderDeclarationSignature`), not raw source slices, so pure
/// reformatting between versions doesn't read as a signature change.
/// `signatureChange` is present — with `changed: false` — even when the two
/// renderings are identical.
///
/// See `issues/pubdev-context-v1/08-get-api-diff.md` (S9) and
/// `issues/fr-tools-disposition/04-api-diff-signature-changes.md`.
library;

import 'package:dart_mcp/server.dart';

import '../analysis/ast_access.dart';
import '../analysis/signature_render.dart';
import '../cache/cache_registry.dart';
import '../cache/keyed_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import 'symbol_bounded_slice.dart';
import 'symbol_resolution.dart';
import 'tool_response.dart';

/// Handles calls to the `get_api_diff` MCP tool.
///
/// Resolves each version's dartdoc symbol index through `apiIndex` before
/// issuing any HTTP request. Logs at [LoggingLevel.info] via `log`.
final class GetApiDiffHandler {
  /// Creates a [GetApiDiffHandler].
  ///
  /// [apiIndex] is the shared [KeyedCache] facade (from `CacheRegistry`) that
  /// resolves and caches the dartdoc symbol index by [ApiIndexId]; pass the
  /// same instance used by `browse_api_symbols` so both modules warm each
  /// other's cache. [astAccess] resolves source files and their parsed ASTs
  /// for `includeSignatureChanges` — pass the same instance used by
  /// `GetSourceSliceHandler`/`GetThrowStatementsHandler` so all three share
  /// both caches; unused by the default (no-`includeSignatureChanges`) call.
  /// [log] receives structured log events at the appropriate [LoggingLevel].
  const GetApiDiffHandler({
    required KeyedCache<ApiIndexId, List<DartdocSymbol>> apiIndex,
    required AstAccess astAccess,
    required void Function(LoggingLevel, Object) log,
  }) : _apiIndex = apiIndex,
       _astAccess = astAccess,
       _log = log;

  final KeyedCache<ApiIndexId, List<DartdocSymbol>> _apiIndex;
  final AstAccess _astAccess;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `get_api_diff`.
  ///
  /// Validates that `package`, `fromVersion`, and `toVersion` are all present
  /// (and, when `includeSignatureChanges` is `true`, that `symbol` is too),
  /// loads both dartdoc indexes (concurrently, via `apiIndex`), and serialises
  /// the added/removed symbol sets — plus a `signatureChange` entry when
  /// `includeSignatureChanges` was requested. Returns [CallToolResult.isError]
  /// `true` with a structured JSON payload on any domain failure.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};

    final package = (args['package'] as String?) ?? '';
    final fromVersion = (args['fromVersion'] as String?) ?? '';
    final toVersion = (args['toVersion'] as String?) ?? '';
    final includeSignatureChanges = (args['includeSignatureChanges'] as bool?) ?? false;
    final rawSymbol = args['symbol'] as String?;
    final symbol = (rawSymbol == null || rawSymbol.isEmpty) ? null : rawSymbol;

    if (package.isEmpty || fromVersion.isEmpty || toVersion.isEmpty) {
      return ToolResponse.error(
        const DomainError(
          code: DomainErrors.invalidArgument,
          message: 'package, fromVersion, and toVersion are all required.',
          suggestion:
              'Supply the package name and two explicit version strings, '
              'e.g. { "package": "http", "fromVersion": "0.13.0", "toVersion": "1.2.0" }.',
        ),
      );
    }

    if (includeSignatureChanges && symbol == null) {
      return ToolResponse.error(
        const DomainError(
          code: DomainErrors.invalidArgument,
          message:
              '`includeSignatureChanges` requires `symbol` — there is no whole-package '
              'structural scan.',
          suggestion:
              'Supply the `symbol` whose signature you want compared, '
              'e.g. { "includeSignatureChanges": true, "symbol": "Client.send" }.',
        ),
      );
    }

    _log(
      LoggingLevel.info,
      'get_api_diff: package=$package fromVersion=$fromVersion toVersion=$toVersion'
      '${symbol != null ? ' symbol=$symbol' : ''}',
    );

    // ── Load both indexes (concurrently, via the shared apiIndex facade) ────────

    final results = await Future.wait([
      _apiIndex.resolve((name: package, version: fromVersion)),
      _apiIndex.resolve((name: package, version: toVersion)),
    ]);
    final fromResult = results[0];
    final toResult = results[1];

    // Propagate transient/real failures (rate-limited, service-unavailable, …)
    // before treating anything as a missing-docs case.
    if (fromResult case PubDevFailure(:final error)) return ToolResponse.error(error);
    if (toResult case PubDevFailure(:final error)) return ToolResponse.error(error);

    final fromSymbols = (fromResult as PubDevSuccess<List<DartdocSymbol>>).value;
    final toSymbols = (toResult as PubDevSuccess<List<DartdocSymbol>>).value;

    if (fromSymbols.isEmpty) return _documentationNotFound(package, fromVersion);
    if (toSymbols.isEmpty) return _documentationNotFound(package, toVersion);

    final json = _buildDiffJson(package, fromVersion, toVersion, fromSymbols, toSymbols);

    if (includeSignatureChanges && symbol != null) {
      switch (await _resolveSignatureChange(
        package: package,
        fromVersion: fromVersion,
        toVersion: toVersion,
        fromSymbols: fromSymbols,
        toSymbols: toSymbols,
        symbol: symbol,
      )) {
        case PubDevFailure(:final error):
          return ToolResponse.error(error);
        case PubDevSuccess(:final value):
          json['signatureChange'] = value;
      }
    }

    return ToolResponse.ok(json);
  }

  /// Diffs [fromSymbols] against [toSymbols] and returns the result as a JSON
  /// map (not yet wrapped in a [CallToolResult] — `call` may still add a
  /// `signatureChange` entry before serialising).
  ///
  /// Symbols are keyed by [DartdocSymbol.qualifiedName]; the first occurrence
  /// of a duplicated qualified name wins. Each added/removed symbol is bucketed
  /// by its [DartdocSymbol.type]; symbols whose kind does not map to one of the
  /// four buckets (e.g. parameters, prefixes) are dropped. Bucket lists are
  /// sorted alphabetically for stable output.
  static Map<String, Object?> _buildDiffJson(
    String package,
    String fromVersion,
    String toVersion,
    List<DartdocSymbol> fromSymbols,
    List<DartdocSymbol> toSymbols,
  ) {
    final fromByName = <String, DartdocSymbol>{
      for (final s in fromSymbols)
        if (s.qualifiedName.isNotEmpty) s.qualifiedName: s,
    };
    final toByName = <String, DartdocSymbol>{
      for (final s in toSymbols)
        if (s.qualifiedName.isNotEmpty) s.qualifiedName: s,
    };

    final added = [
      for (final entry in toByName.entries)
        if (!fromByName.containsKey(entry.key)) entry.value,
    ];
    final removed = [
      for (final entry in fromByName.entries)
        if (!toByName.containsKey(entry.key)) entry.value,
    ];

    return {
      'package': package,
      'fromVersion': fromVersion,
      'toVersion': toVersion,
      'added': _bucketize(added),
      'removed': _bucketize(removed),
    };
  }

  /// Groups [symbols] into the four API-surface buckets, dropping any symbol
  /// whose kind does not map to a bucket, and sorts each bucket alphabetically.
  static Map<String, List<String>> _bucketize(List<DartdocSymbol> symbols) {
    final buckets = <String, List<String>>{
      'libraries': [],
      'classes': [],
      'methods': [],
      'fields': [],
    };
    for (final s in symbols) {
      final bucket = _bucketFor(s.type);
      if (bucket != null) buckets[bucket]?.add(s.qualifiedName);
    }
    for (final list in buckets.values) {
      list.sort();
    }
    return buckets;
  }

  /// Maps a dartdoc symbol [type] to one of the four API-surface buckets, or
  /// `null` when the kind is not part of the tracked public surface.
  static String? _bucketFor(String type) => switch (type) {
    'library' => 'libraries',
    'class' || 'mixin' || 'enum' || 'extension' || 'extension-type' || 'typedef' => 'classes',
    'method' || 'function' || 'constructor' => 'methods',
    'property' ||
    'accessor' ||
    'constant' ||
    'top-level-constant' ||
    'top-level-property' => 'fields',
    _ => null,
  };

  CallToolResult _documentationNotFound(String package, String version) => ToolResponse.error(
    DomainError(
      code: DomainErrors.documentationNotFound,
      message: 'No dartdoc documentation found for $package version $version.',
      suggestion:
          'Verify that version has dartdoc output on pub.dev. As a manual '
          'workaround, call browse_api_symbols separately for each version.',
      suggestedNextStep: {
        'tool': 'browse_api_symbols',
        'arguments': {'package': package, 'version': version},
      },
    ),
  );

  // ─── includeSignatureChanges ────────────────────────────────────────────────

  /// Resolves `symbol` against both versions' dartdoc indexes, locates its
  /// declaration in both package tarballs, and renders + compares their
  /// signatures.
  ///
  /// Fails with `SYMBOL_NOT_FOUND` when `symbol` isn't present in both
  /// [fromSymbols] and [toSymbols] — it was added or removed rather than
  /// persisting, which the `added`/`removed` buckets already surface — or
  /// with `AMBIGUOUS_SYMBOL` when it resolves to more than one candidate in
  /// either version.
  Future<PubDevResult<Map<String, Object?>>> _resolveSignatureChange({
    required String package,
    required String fromVersion,
    required String toVersion,
    required List<DartdocSymbol> fromSymbols,
    required List<DartdocSymbol> toSymbols,
    required String symbol,
  }) async {
    final fromMatch = resolveDartdocSymbol(fromSymbols, symbol);
    final toMatch = resolveDartdocSymbol(toSymbols, symbol);

    // Resolve both sides before failing, so a symbol missing from both
    // versions names both in one error rather than only the first checked.
    final missingFrom = [
      if (fromMatch is NoSymbolMatch) fromVersion,
      if (toMatch is NoSymbolMatch) toVersion,
    ];
    if (missingFrom.isNotEmpty) {
      return PubDevFailure(
        DomainError(
          code: DomainErrors.symbolNotFound,
          message:
              'Symbol "$symbol" was not found in ${missingFrom.join(' and ')} — '
              'includeSignatureChanges requires it to be present in both fromVersion and '
              'toVersion.',
          suggestion:
              'Check the added/removed buckets in this response — the symbol may have '
              'been added or removed rather than persisting across both versions.',
        ),
      );
    }

    if (fromMatch case AmbiguousSymbolMatch(:final alternatives)) {
      return PubDevFailure(_ambiguousError(symbol, fromVersion, alternatives));
    }
    if (toMatch case AmbiguousSymbolMatch(:final alternatives)) {
      return PubDevFailure(_ambiguousError(symbol, toVersion, alternatives));
    }

    final fromSym = (fromMatch as SingleSymbolMatch).symbol;
    final toSym = (toMatch as SingleSymbolMatch).symbol;

    final beforeResult = await _renderSignature(package, fromVersion, fromSym);
    if (beforeResult case PubDevFailure(:final error)) return PubDevFailure(error);
    final afterResult = await _renderSignature(package, toVersion, toSym);
    if (afterResult case PubDevFailure(:final error)) return PubDevFailure(error);

    final before = (beforeResult as PubDevSuccess<String>).value;
    final after = (afterResult as PubDevSuccess<String>).value;

    return PubDevSuccess({
      'qualifiedName': toSym.qualifiedName,
      'changed': before != after,
      'before': before,
      'after': after,
    });
  }

  /// Builds an `AMBIGUOUS_SYMBOL` error for [symbol] resolving to more than
  /// one candidate in [version].
  static DomainError _ambiguousError(String symbol, String version, List<String> alternatives) =>
      DomainError(
        code: DomainErrors.ambiguousSymbol,
        message:
            'Symbol "$symbol" is ambiguous in $version — '
            '${alternatives.length} candidates found.',
        suggestion: 'Retry with a fully qualified name from the candidates list.',
        details: {'candidates': alternatives},
      );

  /// Locates [sym]'s declaration in [package] [version]'s tarball and renders
  /// its signature.
  ///
  /// Tries the dartdoc `href`'s implied source paths first, then falls back
  /// to scanning every `.dart` file — mirroring `get_throw_statements`'s
  /// top-level-function resolution, since a package's re-exporting `lib/`
  /// structure often doesn't match its dartdoc library-name convention.
  Future<PubDevResult<String>> _renderSignature(
    String package,
    String version,
    DartdocSymbol sym,
  ) async {
    final localName = sym.enclosedBy != null ? '${sym.enclosedBy}.${sym.name}' : sym.name;

    final Map<String, String> files;
    switch (await _astAccess.sourceFiles(package, version)) {
      case PubDevFailure(:final error):
        return PubDevFailure(error);
      case PubDevSuccess(:final value):
        files = value;
    }

    for (final path in _candidatePaths(sym.href, files)) {
      switch (await _astAccess.unit(package, version, path)) {
        case PubDevFailure(:final error):
          // path came from the sourceFiles map already loaded above for this
          // same (package, version), so unit() cannot fail here.
          throw StateError('unexpected failure parsing an already-listed source file: $error');
        case PubDevSuccess(value: final ast):
          final node = findDeclarationNode(_astAccess, ast.unit, localName);
          if (node != null) return PubDevSuccess(renderDeclarationSignature(node));
      }
    }

    return PubDevFailure(
      DomainError(
        code: DomainErrors.symbolNotFound,
        message:
            'Declaration for "$localName" could not be located in the source files of '
            '$package $version.',
        suggestion:
            'The symbol may be generated, conditionally exported, or defined in a part file. '
            'Try get_source_slice to inspect the relevant file directly.',
      ),
    );
  }

  /// Returns candidate source-file paths for [href], most-likely-first: the
  /// href's implied `lib/{name}.dart`/`lib/src/{name}.dart` locations (when
  /// present in [files]), followed by every remaining `.dart` file.
  static List<String> _candidatePaths(String href, Map<String, String> files) {
    final hinted = _hrefToSourcePaths(href).where(files.containsKey).toList();
    final hintedSet = hinted.toSet();
    return [
      ...hinted,
      ...files.keys.where((k) => k.endsWith('.dart') && !hintedSet.contains(k)),
    ];
  }

  /// Maps a dartdoc href to candidate source file paths.
  static List<String> _hrefToSourcePaths(String href) {
    final slash = href.indexOf('/');
    if (slash <= 0) return const [];
    final libraryName = href.substring(0, slash);
    return ['lib/$libraryName.dart', 'lib/src/$libraryName.dart'];
  }
}
