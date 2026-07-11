/// Parses raw Keep-a-Changelog markdown text into [ChangelogEntry] values.
///
/// Extracted from `get_changelog.dart` so the `changelog` `KeyedCache` facade
/// in `CacheRegistry` can parse a fetched changelog on a cache miss without
/// importing the tool handler (which itself depends on `CacheRegistry` for the
/// facade's `Id` type).
library;

import 'models.dart';

/// Matches a Keep-a-Changelog version heading at the start of a line.
///
/// Handles both `## 1.2.3` and `## [1.2.3]` formats; the first capture group
/// contains the version string (without surrounding brackets when present).
final _kHeadingPattern = RegExp(r'^## \[?(\d+\.\d+\.\d+[^\]]*)\]?');

/// Parses [text] into a newest-first list of [ChangelogEntry] values.
///
/// Splits [text] line-by-line on headings matching [_kHeadingPattern]. The
/// text between consecutive headings becomes the [ChangelogEntry.changes] for
/// that version. Returns an empty list when no version headings are found.
List<ChangelogEntry> parseChangelogText(String text) {
  final lines = text.split('\n');
  final entries = <ChangelogEntry>[];
  String? currentVersion;
  final currentChanges = StringBuffer();

  for (final line in lines) {
    final match = _kHeadingPattern.firstMatch(line);
    final version = match?.group(1)?.trim();
    if (version != null && version.isNotEmpty) {
      if (currentVersion != null) {
        _flushEntry(entries, currentVersion, currentChanges);
        currentChanges.clear();
      }
      currentVersion = version;
    } else if (currentVersion != null) {
      currentChanges.writeln(line);
    }
  }

  if (currentVersion != null) {
    _flushEntry(entries, currentVersion, currentChanges);
  }

  return entries;
}

void _flushEntry(List<ChangelogEntry> entries, String version, StringBuffer changesBuffer) {
  final changes = changesBuffer.toString().trim();
  entries.add(
    ChangelogEntry(
      version: version,
      date: null,
      changes: changes,
      breaking: changes.toLowerCase().contains('breaking'),
    ),
  );
}
