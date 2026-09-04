/// Parses raw SDK markdown changelogs into [SdkReleaseNotesEntry] values.
library;

import 'models.dart';

/// Matches a version heading at the start of a line.
///
/// Handles `## 3.14.0`, `## 3.14.0 - 2025-01-15`, `## 3.24.1 (2024-08-06)`,
/// and bracketed `## [3.5.0]`.
final _kVersionHeadingPattern = RegExp(
  r'^##\s+\[?(\d+\.\d+\.\d+[a-zA-Z0-9.+_-]*)\]?(?:\s*[-–—(]\s*(\d{4}-\d{2}-\d{2})|\s*[-–—(]\s*([^)\n]+)\)?)?',
);

/// Matches an isolated ISO 8601 date string (e.g. `2024-08-06`).
final _kDatePattern = RegExp(r'\b(\d{4}-\d{2}-\d{2})\b');

/// Matches a section heading (level 3: `### Language`).
final _kSectionHeadingPattern = RegExp(r'^###\s+(.*)');

/// Matches a subsystem heading (level 4: `#### dart:core` or `#### `dart:ffi``).
final _kSubsystemHeadingPattern = RegExp(r'^####\s+(.*)');

/// Matches the start of a bullet or list item (`- `, `* `, `+ `, `1. `).
final _kListItemStartPattern = RegExp(r'^\s*(?:[-*+]|\d+\.)\s+(.*)');

/// Parses [text] into a newest-first list of [SdkReleaseNotesEntry] values.
List<SdkReleaseNotesEntry> parseSdkChangelogText(String text) {
  final lines = text.split('\n');
  final entries = <SdkReleaseNotesEntry>[];

  String? currentVersion;
  DateTime? currentDate;
  final currentSections = <String, List<String>>{};
  final currentChanges = <String>[];

  String? currentSection;
  String? currentSubsystem;
  String? currentItem;

  void flushItem() {
    final itemRaw = currentItem;
    if (itemRaw == null) return;
    var item = itemRaw.trim();
    currentItem = null;
    if (item.isEmpty) return;

    final subsystem = currentSubsystem;
    if (subsystem != null && subsystem.isNotEmpty) {
      final prefix = '$subsystem:';
      if (!item.startsWith(prefix) && !item.startsWith(subsystem)) {
        item = '$prefix $item';
      }
    }

    final sectionName = currentSection ?? 'General';
    currentSections.putIfAbsent(sectionName, () => []).add(item);
    currentChanges.add(item);
  }

  void flushEntry() {
    flushItem();
    final ver = currentVersion;
    if (ver == null) return;

    final isBreaking =
        currentSections.keys.any((s) => s.toLowerCase().contains('breaking')) ||
        currentChanges.any((c) => c.toLowerCase().contains('breaking'));

    entries.add(
      SdkReleaseNotesEntry(
        version: ver,
        date: currentDate,
        changes: List.unmodifiable(currentChanges),
        sections: {
          for (final entry in currentSections.entries) entry.key: List.unmodifiable(entry.value),
        },
        breaking: isBreaking,
      ),
    );

    currentVersion = null;
    currentDate = null;
    currentSections.clear();
    currentChanges.clear();
    currentSection = null;
    currentSubsystem = null;
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
      // Preamble before first version heading
      continue;
    }

    final sectionMatch = _kSectionHeadingPattern.firstMatch(line);
    if (sectionMatch != null) {
      flushItem();
      currentSection = _cleanHeading(sectionMatch.group(1) ?? '');
      currentSubsystem = null;
      continue;
    }

    final subsystemMatch = _kSubsystemHeadingPattern.firstMatch(line);
    if (subsystemMatch != null) {
      flushItem();
      currentSubsystem = _cleanHeading(subsystemMatch.group(1) ?? '');
      continue;
    }

    final listMatch = _kListItemStartPattern.firstMatch(line);
    if (listMatch != null) {
      flushItem();
      currentItem = listMatch.group(1)?.trim();
      continue;
    }

    // Continuation line or blank line
    if (line.trim().isEmpty) {
      flushItem();
    } else if (currentItem != null) {
      // Multi-line continuation
      currentItem = '$currentItem ${line.trim()}';
    } else if (line.trim().isNotEmpty && !line.startsWith('#')) {
      // Non-bullet paragraph text
      currentItem = line.trim();
    }
  }

  flushEntry();

  return entries;
}

String _cleanHeading(String raw) {
  var cleaned = raw.trim();
  if (cleaned.startsWith('`') && cleaned.endsWith('`') && cleaned.length >= 2) {
    cleaned = cleaned.substring(1, cleaned.length - 1);
  }
  return cleaned.trim();
}
