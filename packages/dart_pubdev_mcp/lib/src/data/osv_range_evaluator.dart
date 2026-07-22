/// Evaluates OSV `affected` ranges against a concrete package version.
///
/// The per-version evaluation is the design content of `get_security_advisories`
/// (see `issues/fr-tools-disposition/02-security-advisories-tool.md`): pub.dev's
/// advisories endpoint reports every advisory ever published against a package,
/// unfiltered by version, so the caller's Resolved Version must be checked
/// against each advisory's OSV ranges to know whether it is actually affected.
library;

import 'package:pub_semver/pub_semver.dart';

import 'models.dart';

/// Returns whether any range in [ranges] affects [version], per the OSV
/// range-evaluation algorithm: within a range, walk its events in order,
/// tracking an "affected" flag that flips true on `introduced` and false on
/// `fixed`/`lastAffected`/`limit`. Ranges are OR'd together — any single
/// matching range is enough. Returns `false` when [version] cannot be parsed
/// as semver.
bool osvRangesAffectVersion(List<OsvRange> ranges, String version) {
  final parsed = _tryParse(version);
  if (parsed == null) return false;
  return ranges.any((range) => _rangeAffects(range, parsed));
}

/// Applies one [OsvRange]'s events, in order, against [version].
///
/// `introduced: "0"` is the OSV sentinel for "affected since the beginning of
/// time" and is treated as an unconditional match rather than parsed as
/// semver. `fixed` and `limit` are exclusive-from boundaries
/// (`version >= boundary` clears the affected flag); `lastAffected` is
/// inclusive (`version > lastAffected` clears it). An event whose version
/// string fails to parse is skipped rather than treated as a match.
bool _rangeAffects(OsvRange range, Version version) {
  var affected = false;
  for (final event in range.events) {
    final introduced = event.introduced;
    final fixed = event.fixed;
    final lastAffected = event.lastAffected;
    final limit = event.limit;

    if (introduced != null) {
      if (introduced == '0') {
        affected = true;
      } else {
        final introducedVersion = _tryParse(introduced);
        if (introducedVersion != null && version >= introducedVersion) affected = true;
      }
    } else if (fixed != null) {
      final fixedVersion = _tryParse(fixed);
      if (fixedVersion != null && version >= fixedVersion) affected = false;
    } else if (lastAffected != null) {
      final lastAffectedVersion = _tryParse(lastAffected);
      if (lastAffectedVersion != null && version > lastAffectedVersion) affected = false;
    } else if (limit != null) {
      final limitVersion = _tryParse(limit);
      if (limitVersion != null && version >= limitVersion) affected = false;
    }
  }
  return affected;
}

Version? _tryParse(String text) {
  try {
    return Version.parse(text);
  } on FormatException {
    return null;
  }
}
