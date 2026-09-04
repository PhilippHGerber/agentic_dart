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
/// Handles `## 1.2.3`, `## [1.2.3]`, `## 1.2.3 - 2024-01-15`, `## 1.2.3 (2024-01-15)`.
final _kVersionHeadingPattern = RegExp(
  r'^##\s+\[?(\d+\.\d+\.\d+[a-zA-Z0-9.+_-]*)\]?(?:\s*[-–—(]\s*(\d{4}-\d{2}-\d{2})|\s*[-–—(]\s*([^)\n]+)\)?)?',
);

/// Matches an isolated ISO 8601 date string (e.g. `2024-08-06`).
final _kDatePattern = RegExp(r'\b(\d{4}-\d{2}-\d{2})\b');

/// Matches the start of a bullet or list item (`- `, `* `, `+ `, `1. `).
final _kListItemStartPattern = RegExp(r'^\s*(?:[-*+]|\d+\.)\s+(.*)');

/// Parses [text] into a newest-first list of [ChangelogEntry] values.
///
/// Splits [text] line-by-line on headings matching [_kVersionHeadingPattern].
/// Each entry contains parsed change bullet strings in [ChangelogEntry.changes]
/// and unparsed section markdown in [ChangelogEntry.rawText].
/// Returns an empty list when no version headings are found.
List<ChangelogEntry> parseChangelogText(String text) {
  final lines = text.split('\n');
  final entries = <ChangelogEntry>[];

  String? currentVersion;
  DateTime? currentDate;
  final currentChanges = <String>[];
  final rawTextBuffer = StringBuffer();
  String? currentItem;

  void flushItem() {
    final itemRaw = currentItem;
    if (itemRaw == null) return;
    final item = itemRaw.trim();
    currentItem = null;
    if (item.isNotEmpty) {
      currentChanges.add(item);
    }
  }

  void flushEntry() {
    flushItem();
    final ver = currentVersion;
    if (ver == null) return;

    final rawText = rawTextBuffer.toString().trim();
    final isBreaking =
        rawText.toLowerCase().contains('breaking') ||
        currentChanges.any((c) => c.toLowerCase().contains('breaking'));

    entries.add(
      ChangelogEntry(
        version: ver,
        date: currentDate,
        changes: List.unmodifiable(currentChanges),
        rawText: rawText,
        breaking: isBreaking,
      ),
    );

    currentVersion = null;
    currentDate = null;
    currentChanges.clear();
    rawTextBuffer.clear();
    currentItem = null;
  }

  for (final rawLine in lines) {
    final line = rawLine.trimRight();

    final versionMatch = _kVersionHeadingPattern.firstMatch(line);
    if (versionMatch != null) {
      flushEntry();
      currentVersion = versionMatch.group(1)?.trim();

      final dateCandidate = versionMatch.group(2) ?? versionMatch.group(3);
      if (dateCandidate != null) {
        final dateMatch = _kDatePattern.firstMatch(dateCandidate);
        if (dateMatch != null) {
          final dateStr = dateMatch.group(1);
          if (dateStr != null) {
            currentDate =
                DateTime.tryParse('${dateStr}T00:00:00.000Z') ??
                DateTime.tryParse(dateStr)?.toUtc();
          }
        }
      }
      continue;
    }

    if (currentVersion == null) {
      continue;
    }

    rawTextBuffer.writeln(rawLine);

    final listMatch = _kListItemStartPattern.firstMatch(line);
    if (listMatch != null) {
      flushItem();
      currentItem = listMatch.group(1)?.trim();
      continue;
    }

    if (line.trim().isEmpty) {
      flushItem();
    } else if (currentItem != null) {
      currentItem = '$currentItem ${line.trim()}';
    } else if (line.trim().isNotEmpty && !line.startsWith('#')) {
      currentItem = line.trim();
    }
  }

  flushEntry();

  return entries;
}
