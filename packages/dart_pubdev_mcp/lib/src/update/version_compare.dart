/// Shared newer-than comparison for the dotted-numeric version strings this
/// server compares against itself: the running executable's version against
/// `dart_pubdev_mcp`'s Latest Stable Version on pub.dev (see `CONTEXT.md`'s
/// **Update Check** glossary entry).
///
/// Used by the `UpdateChecker` itself and by read-only consumers of its
/// persisted state — like the Update Banner on `--version` — that need the
/// identical comparison without pulling in the rest of the Update Check
/// machinery.
library;

/// Whether [candidate] is a strictly newer dotted-numeric version than
/// [base]. Compares each `.`-separated segment numerically, treating a
/// missing trailing segment as `0`; a non-numeric segment falls back to
/// string comparison for that segment only. Sufficient here because this
/// server's own version strings are always plain `x.y.z` with no pre-release
/// suffix — full semver precedence rules are not needed.
bool isNewerVersion(String candidate, String base) {
  final candidateParts = candidate.split('.');
  final baseParts = base.split('.');
  final length = candidateParts.length > baseParts.length
      ? candidateParts.length
      : baseParts.length;
  for (var i = 0; i < length; i++) {
    final candidatePart = i < candidateParts.length ? candidateParts[i] : '0';
    final basePart = i < baseParts.length ? baseParts[i] : '0';
    final candidateNum = int.tryParse(candidatePart);
    final baseNum = int.tryParse(basePart);
    final comparison = (candidateNum != null && baseNum != null)
        ? candidateNum.compareTo(baseNum)
        : candidatePart.compareTo(basePart);
    if (comparison != 0) return comparison > 0;
  }
  return false;
}
