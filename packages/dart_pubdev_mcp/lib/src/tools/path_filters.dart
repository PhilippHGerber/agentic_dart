/// Path-prefix normalization shared by every tool that accepts a `directory`
/// filter over a package's or SDK's source-file map —
/// `list_package_source_files`, `grep_package_source`, and `grep_sdk_source`.
library;

/// Normalizes a caller-supplied `directory` filter.
///
/// Strips a leading slash and ensures a trailing slash (so prefix matching
/// only matches whole directory segments, not partial names). Returns `null`
/// when [raw] is `null`.
String? normalizeDirectory(String? raw) {
  if (raw == null) return null;
  var dir = raw.startsWith('/') ? raw.substring(1) : raw;
  if (!dir.endsWith('/') && dir.isNotEmpty) dir = '$dir/';
  return dir;
}

/// Returns whether [path] satisfies a caller-supplied `directory` filter.
///
/// Matches [path] either as living under the [rawDirectory] folder prefix
/// (via [normalizeDirectory]) or as being exactly [rawDirectory] itself —
/// callers regularly pass a full file path (e.g. copied from a prior
/// `matches[].file`) expecting it to scope the search to that one file, and
/// prefix-only matching would silently return zero results for that case
/// since a file path is never a prefix of itself. A `null`/empty
/// [rawDirectory] matches everything.
bool matchesDirectoryFilter(String path, String? rawDirectory) {
  if (rawDirectory == null || rawDirectory.isEmpty) return true;
  final exact = rawDirectory.startsWith('/') ? rawDirectory.substring(1) : rawDirectory;
  final prefix = normalizeDirectory(rawDirectory);
  if (prefix == null) return true;
  return path.startsWith(prefix) || path == exact;
}
