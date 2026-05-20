/// Handler for the `get_changelog` MCP tool.
///
/// Returns a recent `List<ChangelogEntry>` for a package, with computed
/// `breaking` flags. Entries are ordered newest-first (file order assumed
/// newest-first per the Keep a Changelog convention).
///
/// See `issues/pub-dev-mcp/07-get-changelog-tool.md`.
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../cache/memory_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import '../data/pub_client.dart';

// ─── Regex patterns ───────────────────────────────────────────────────────────

/// Matches a Keep-a-Changelog version heading at the start of a line.
///
/// Handles both `## 1.2.3` and `## [1.2.3]` formats; the first capture group
/// contains the version string (without surrounding brackets when present).
final _kHeadingPattern = RegExp(r'^## \[?(\d+\.\d+\.\d+[^\]]*)\]?');

/// Strips non-numeric suffixes from a single version component.
///
/// `"3-beta"` → `"3"`, `"2024"` → `"2024"`.
final _kNonNumericSuffix = RegExp('[^0-9].*');

// ─── Domain error constants ───────────────────────────────────────────────────

const _noDocumentation = DomainError(
  error: DomainErrors.noDocumentation,
  message: 'The package changelog contains no version headings.',
  suggestion:
      'The package may use a non-standard changelog format. '
      'Check the package page on pub.dev for release notes.',
);

const _invalidInput = DomainError(
  error: DomainErrors.invalidInput,
  message: 'The from_version value is older than all entries in the changelog.',
  suggestion:
      'Supply a from_version that appears in the changelog, or omit it '
      'to retrieve the most recent entries.',
);

// ─── Handler ──────────────────────────────────────────────────────────────────

/// Handles calls to the `get_changelog` MCP tool.
///
/// Consults the cache before issuing HTTP requests; stores the full parsed entry
/// list with [kChangelogTtl] so the same data can be reused across calls with
/// different `fromVersion` and `versionLimit` values. HTTP failures are not
/// cached so transient errors can be retried.
final class GetChangelogHandler {
  /// Creates a [GetChangelogHandler].
  ///
  /// [client] is the pub.dev HTTP gateway. [cache] holds the full unfiltered
  /// entry list keyed by package name. [log] receives structured log events at
  /// the appropriate [LoggingLevel].
  const GetChangelogHandler({
    required PubDevClient client,
    required ResponseCache<List<ChangelogEntry>> cache,
    required void Function(LoggingLevel, Object) log,
  }) : _client = client,
       _cache = cache,
       _log = log;

  final PubDevClient _client;
  final ResponseCache<List<ChangelogEntry>> _cache;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `get_changelog`.
  ///
  /// Looks up the full [ChangelogEntry] list in cache, or fetches and parses it
  /// from pub.dev. Applies the `fromVersion` boundary and `versionLimit` cap on
  /// each call. Returns [CallToolResult.isError] `true` on any domain failure.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final name = (args['name'] as String?) ?? '';
    final versionLimit = (args['version_limit'] as int?) ?? 5;
    final fromVersion = args['from_version'] as String?;

    final cacheKey = 'changelog:$name';

    _log(
      LoggingLevel.info,
      'get_changelog: name=$name'
      '${fromVersion != null ? ' from_version=$fromVersion' : ''}',
    );

    final cached = _cache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'get_changelog: cache hit key=$cacheKey');
      final entries = await cached;
      if (entries.isEmpty) return _domainError(_noDocumentation);
      return _applyFilters(entries, versionLimit, fromVersion);
    }

    _log(LoggingLevel.debug, 'get_changelog: cache miss key=$cacheKey');
    _log(LoggingLevel.info, 'get_changelog: HTTP request name=$name');

    final result = await _client.getChangelog(name);
    if (result case PubDevFailure<String>(:final error)) {
      return _domainError(error);
    }

    final rawText = (result as PubDevSuccess<String>).value;
    final entries = _parseChangelog(rawText);

    _cache.set(cacheKey, Future.value(entries), kChangelogTtl);

    if (entries.isEmpty) return _domainError(_noDocumentation);
    return _applyFilters(entries, versionLimit, fromVersion);
  }

  // ── Filtering ──────────────────────────────────────────────────────────────

  static CallToolResult _applyFilters(
    List<ChangelogEntry> entries,
    int versionLimit,
    String? fromVersion,
  ) {
    if (fromVersion == null) {
      return _success(entries.take(versionLimit).toList());
    }
    return _applyFromVersion(entries, versionLimit, fromVersion);
  }

  /// Applies the [fromVersion] exclusive lower bound to [entries].
  ///
  /// Returns entries newer than [fromVersion]. When [fromVersion] is not in the
  /// list, the first entry older than it is used as the boundary. Returns
  /// [_invalidInput] when no entry older than [fromVersion] exists.
  static CallToolResult _applyFromVersion(
    List<ChangelogEntry> entries,
    int versionLimit,
    String fromVersion,
  ) {
    var boundaryIdx = entries.indexWhere((e) => e.version == fromVersion);

    if (boundaryIdx < 0) {
      boundaryIdx = entries.indexWhere((e) => _isOlder(e.version, fromVersion));
      if (boundaryIdx < 0) return _domainError(_invalidInput);
    }

    return _success(entries.sublist(0, boundaryIdx).take(versionLimit).toList());
  }

  // ── Parsing ────────────────────────────────────────────────────────────────

  /// Parses [text] into a newest-first list of [ChangelogEntry] values.
  ///
  /// Splits [text] line-by-line on headings matching [_kHeadingPattern]. The
  /// text between consecutive headings becomes the [ChangelogEntry.changes] for
  /// that version. Returns an empty list when no version headings are found.
  static List<ChangelogEntry> _parseChangelog(String text) {
    final lines = text.split('\n');
    final entries = <ChangelogEntry>[];
    String? currentVersion;
    final currentChanges = StringBuffer();

    for (final line in lines) {
      final match = _kHeadingPattern.firstMatch(line);
      if (match != null) {
        if (currentVersion != null) {
          _flushEntry(entries, currentVersion, currentChanges);
          currentChanges.clear();
        }
        currentVersion = match.group(1)!.trim();
      } else if (currentVersion != null) {
        currentChanges.writeln(line);
      }
    }

    if (currentVersion != null) {
      _flushEntry(entries, currentVersion, currentChanges);
    }

    return entries;
  }

  static void _flushEntry(
    List<ChangelogEntry> entries,
    String version,
    StringBuffer changesBuffer,
  ) {
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

  // ── Version comparison ─────────────────────────────────────────────────────

  /// Returns `true` when [v] is semantically older (lower) than [target].
  ///
  /// Compares only the `major.minor.patch` numeric components; pre-release
  /// suffixes and date annotations are stripped before comparison.
  static bool _isOlder(String v, String target) {
    final vParts = _versionParts(v);
    final tParts = _versionParts(target);
    for (var i = 0; i < 3; i++) {
      final cmp = vParts[i].compareTo(tParts[i]);
      if (cmp != 0) return cmp < 0;
    }
    return false;
  }

  /// Extracts the three numeric version components from [version].
  ///
  /// Non-numeric suffixes (pre-release labels, date annotations) are stripped
  /// from each component. Missing components default to 0.
  static List<int> _versionParts(String version) {
    final parts = version.split('.').take(3).map((p) {
      final numeric = p.replaceAll(_kNonNumericSuffix, '');
      return int.tryParse(numeric) ?? 0;
    }).toList();
    while (parts.length < 3) {
      parts.add(0);
    }
    return parts;
  }

  // ── Serialisation ──────────────────────────────────────────────────────────

  static CallToolResult _success(List<ChangelogEntry> entries) => CallToolResult(
    content: [TextContent(text: jsonEncode(entries.map(_entryToJson).toList()))],
  );

  static CallToolResult _domainError(DomainError error) => CallToolResult(
    content: [TextContent(text: error.toJsonString())],
    isError: true,
  );

  static Map<String, Object?> _entryToJson(ChangelogEntry e) => {
    'version': e.version,
    if (e.date != null) 'date': e.date!.toIso8601String(),
    'changes': e.changes,
    'breaking': e.breaking,
  };
}
