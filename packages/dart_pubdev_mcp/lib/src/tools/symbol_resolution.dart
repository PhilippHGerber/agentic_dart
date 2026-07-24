/// Symbol resolution against a package's dartdoc `index.json` — the
/// three-pass name-matching strategy shared by `get_symbol_documentation`
/// (resolving `symbol` to an href) and `get_api_diff`'s
/// `includeSignatureChanges` mode (resolving `symbol` to a [DartdocSymbol] in
/// each of two versions being compared).
library;

import '../data/models.dart';

/// The result of resolving a caller-supplied symbol name against a package's
/// dartdoc index — see [resolveDartdocSymbol].
sealed class SymbolMatch {}

/// Exactly one entry matched.
final class SingleSymbolMatch extends SymbolMatch {
  /// Creates a [SingleSymbolMatch] wrapping the resolved [symbol].
  SingleSymbolMatch(this.symbol);

  /// The resolved dartdoc symbol.
  final DartdocSymbol symbol;
}

/// More than one entry matched and none could be preferred.
final class AmbiguousSymbolMatch extends SymbolMatch {
  /// Creates an [AmbiguousSymbolMatch] carrying the candidates'
  /// [DartdocSymbol.qualifiedName] values.
  AmbiguousSymbolMatch(this.alternatives);

  /// The `qualifiedName` of every candidate that matched.
  final List<String> alternatives;
}

/// No entry matched.
final class NoSymbolMatch extends SymbolMatch {}

/// Resolves [symbol] against [symbols] using a three-pass strategy.
///
/// **Pass 0** — exact [DartdocSymbol.qualifiedName] match. This is the primary
/// retry path after an `AMBIGUOUS_SYMBOL` error: callers pass a value from
/// `error.details.candidates` and the match is always unambiguous.
///
/// **Pass 1** — exact [DartdocSymbol.name] match.
///
/// **Pass 2** — [DartdocSymbol.qualifiedName] suffix match (library prefix
/// stripped up to and including the first `.`).
///
/// Disambiguation: when multiple matches survive pass 1 or pass 2, the
/// class-level entry (`type == "class"`) is preferred. If exactly one class
/// entry exists, it is used. If multiple class entries exist, or no class
/// entry exists and multiple matches remain, an [AmbiguousSymbolMatch] is
/// returned with every candidate's `qualifiedName`.
SymbolMatch resolveDartdocSymbol(List<DartdocSymbol> symbols, String symbol) {
  // Pass 0: exact qualifiedName match — unambiguous retry path.
  final qnMatches = symbols.where((s) => s.qualifiedName == symbol).toList();
  if (qnMatches.length == 1) return SingleSymbolMatch(qnMatches.first);
  if (qnMatches.isNotEmpty) return _disambiguate(qnMatches);

  // Pass 1: exact name match.
  final nameMatches = symbols.where((s) => s.name == symbol).toList();
  if (nameMatches.length == 1) return SingleSymbolMatch(nameMatches.first);
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
SymbolMatch _disambiguate(List<DartdocSymbol> candidates) {
  if (candidates.isEmpty) return NoSymbolMatch();
  if (candidates.length == 1) return SingleSymbolMatch(candidates.first);

  final classEntries = candidates.where((s) => s.type == 'class').toList();
  if (classEntries.length == 1) return SingleSymbolMatch(classEntries.first);

  // Multiple class entries, or no class entry with multiple matches.
  return AmbiguousSymbolMatch(candidates.map((s) => s.qualifiedName).toList());
}
