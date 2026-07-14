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
/// nullability, altered return types) are intentionally out of scope for V1.
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
/// See `issues/pubdev-context-v1/08-get-api-diff.md` (S9).
library;

import 'package:dart_mcp/server.dart';

import '../cache/cache_registry.dart';
import '../cache/keyed_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
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
  /// other's cache. [log] receives structured log events at the appropriate
  /// [LoggingLevel].
  const GetApiDiffHandler({
    required KeyedCache<ApiIndexId, List<DartdocSymbol>> apiIndex,
    required void Function(LoggingLevel, Object) log,
  }) : _apiIndex = apiIndex,
       _log = log;

  final KeyedCache<ApiIndexId, List<DartdocSymbol>> _apiIndex;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `get_api_diff`.
  ///
  /// Validates that `package`, `fromVersion`, and `toVersion` are all present,
  /// loads both dartdoc indexes (concurrently, via `apiIndex`), and serialises
  /// the added/removed symbol sets. Returns [CallToolResult.isError] `true`
  /// with a structured JSON payload on any domain failure.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};

    final package = (args['package'] as String?) ?? '';
    final fromVersion = (args['fromVersion'] as String?) ?? '';
    final toVersion = (args['toVersion'] as String?) ?? '';

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

    _log(
      LoggingLevel.info,
      'get_api_diff: package=$package fromVersion=$fromVersion toVersion=$toVersion',
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

    return _buildResponse(package, fromVersion, toVersion, fromSymbols, toSymbols);
  }

  /// Diffs [fromSymbols] against [toSymbols] and serialises the result.
  ///
  /// Symbols are keyed by [DartdocSymbol.qualifiedName]; the first occurrence
  /// of a duplicated qualified name wins. Each added/removed symbol is bucketed
  /// by its [DartdocSymbol.type]; symbols whose kind does not map to one of the
  /// four buckets (e.g. parameters, prefixes) are dropped. Bucket lists are
  /// sorted alphabetically for stable output.
  CallToolResult _buildResponse(
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

    return ToolResponse.ok({
      'package': package,
      'fromVersion': fromVersion,
      'toVersion': toVersion,
      'added': _bucketize(added),
      'removed': _bucketize(removed),
    });
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
}
