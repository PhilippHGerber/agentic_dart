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
