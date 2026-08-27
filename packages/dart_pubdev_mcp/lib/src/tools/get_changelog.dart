/// Handler for the `get_changelog` MCP tool.
///
/// Returns a recent `List<ChangelogEntry>` for a package, with computed
/// `breaking` flags. Entries are ordered newest-first (file order assumed
/// newest-first per the Keep a Changelog convention).
///
/// See `issues/pub-dev-mcp/07-get-changelog-tool.md`.
library;

import 'package:dart_mcp/server.dart';

import '../cache/cache_registry.dart';
import '../cache/keyed_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import 'sdk_package_guard.dart';
import 'tool_response.dart';
import 'version_resolver.dart';

// ─── Regex patterns ───────────────────────────────────────────────────────────

/// Strips non-numeric suffixes from a single version component.
///
/// `"3-beta"` → `"3"`, `"2024"` → `"2024"`.
final _kNonNumericSuffix = RegExp('[^0-9].*');

// ─── Domain error constants ───────────────────────────────────────────────────

const _noDocumentation = DomainError(
  code: DomainErrors.noDocumentation,
  message: 'The package changelog contains no version headings.',
  suggestion:
      'The package may use a non-standard changelog format. '
      'Check the package page on pub.dev for release notes.',
);

const _invalidInput = DomainError(
  code: DomainErrors.invalidArgument,
  message: 'The fromVersion value is older than all entries in the changelog.',
  suggestion:
      'Supply a fromVersion that appears in the changelog, or omit it '
      'to retrieve the most recent entries.',
);

// ─── Handler ──────────────────────────────────────────────────────────────────

/// Handles calls to the `get_changelog` MCP tool.
///
/// Resolves the full parsed entry list through the shared `changelog`
/// [KeyedCache] facade (from `CacheRegistry`), keyed by package `name`, so the
/// same data is reused across calls with different `fromVersion` and
/// `versionLimit` values. HTTP failures are not cached so transient errors can
/// be retried.
final class GetChangelogHandler {
  /// Creates a [GetChangelogHandler].
  ///
  /// [versionResolver] resolves the Resolved Version, falling back to the
  /// Latest Stable Version when the caller omits one. [changelog] is the
  /// shared [KeyedCache] facade (from `CacheRegistry`) that resolves and
  /// caches the full parsed entry list by [ChangelogEntriesId]. [log] receives
  /// structured log events at the appropriate [LoggingLevel].
  const GetChangelogHandler({
    required VersionResolver versionResolver,
    required KeyedCache<ChangelogEntriesId, List<ChangelogEntry>> changelog,
    required void Function(LoggingLevel, Object) log,
  }) : _versionResolver = versionResolver,
       _changelog = changelog,
       _log = log;

  final VersionResolver _versionResolver;
  final KeyedCache<ChangelogEntriesId, List<ChangelogEntry>> _changelog;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `get_changelog`.
  ///
  /// Resolves the latest stable version via [VersionResolver] (or validates the
  /// caller-supplied `version`) to include `resolvedVersion` in the success
  /// response. Resolves the full [ChangelogEntry] list through `changelog`.
  /// Applies the `fromVersion` boundary and `versionLimit` cap on each call.
  /// Returns [CallToolResult.isError] `true` on any domain failure.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final package = (args['package'] as String?) ?? '';
    final versionLimit = (args['limit'] as int?) ?? 5;
    final fromVersion = args['fromVersion'] as String?;
    final suppliedVersion = args['version'] as String?;

    // Checked before touching VersionResolver/PubDevClient so an SDK package
    // name (e.g. "flutter") never reaches either.
    if (sdkPackageGuardError(package) case final error?) return ToolResponse.error(error);

    _log(
      LoggingLevel.info,
      'get_changelog: package=$package'
      '${suppliedVersion != null ? ' version=$suppliedVersion' : ''}'
      '${fromVersion != null ? ' fromVersion=$fromVersion' : ''}',
    );

    // Trade-off: we resolve version up front on every call, even on a changelog
    // cache hit. This costs one lightweight JSON GET but keeps the
    // `resolvedVersion` field correct and the control flow simple. Deriving the
    // version from the changelog instead would be unsound — the newest heading
    // may be a pre-release, not the latest stable.
    final String resolvedVersion;
    switch (await _versionResolver.resolve(
      package: package,
      supplied: suppliedVersion,
      tool: 'get_changelog',
    )) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        resolvedVersion = value;
    }

    // `changelog` is keyed by package name only (no version segment): the full
    // changelog text covers every released version, so one cached parse serves
    // all `fromVersion`/`limit` queries. `resolvedVersion` only labels
    // the response and must not narrow the identity.
    final List<ChangelogEntry> entries;
    switch (await _changelog.resolve((name: package))) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        entries = value;
    }

    if (entries.isEmpty) return ToolResponse.error(_noDocumentation);
    return _applyFilters(
      entries: entries,
      package: package,
      versionLimit: versionLimit,
      suppliedVersion: suppliedVersion,
      fromVersion: fromVersion,
      resolvedVersion: resolvedVersion,
    );
  }

  // ── Filtering ──────────────────────────────────────────────────────────────

  static CallToolResult _applyFilters({
    required List<ChangelogEntry> entries,
    required String package,
    required int versionLimit,
    required String? suppliedVersion,
    required String? fromVersion,
    required String resolvedVersion,
  }) {
    final int targetIndex;
    if (suppliedVersion == null) {
      targetIndex = 0;
    } else {
      final exactIndex = entries.indexWhere((e) => _matchesVersion(e.version, resolvedVersion));
      if (exactIndex >= 0) {
        targetIndex = exactIndex;
      } else {
        final nextOlder = entries.indexWhere((e) => _isOlder(e.version, resolvedVersion));
        targetIndex = nextOlder >= 0 ? nextOlder : 0;
      }
    }

    if (fromVersion == null) {
      return _success(
        entries.sublist(targetIndex).take(versionLimit).toList(),
        package,
        resolvedVersion,
      );
    }
    return _applyFromVersion(
      entries: entries,
      package: package,
      targetIndex: targetIndex,
      versionLimit: versionLimit,
      fromVersion: fromVersion,
      resolvedVersion: resolvedVersion,
    );
  }

  /// Applies the [fromVersion] exclusive lower bound to [entries].
  ///
  /// Returns entries newer than [fromVersion]. When [fromVersion] is not in the
  /// list, the first entry older than it is used as the boundary. Returns
  /// [_invalidInput] when no entry older than [fromVersion] exists.
  static CallToolResult _applyFromVersion({
    required List<ChangelogEntry> entries,
    required String package,
    required int targetIndex,
    required int versionLimit,
    required String fromVersion,
    required String resolvedVersion,
  }) {
    var boundaryIdx = entries.indexWhere((e) => _matchesVersion(e.version, fromVersion));

    if (boundaryIdx < 0) {
      boundaryIdx = entries.indexWhere((e) => _isOlder(e.version, fromVersion));
      if (boundaryIdx < 0) return ToolResponse.error(_invalidInput);
    }

    if (boundaryIdx < targetIndex) {
      return ToolResponse.error(
        DomainError(
          code: DomainErrors.invalidArgument,
          message:
              'fromVersion ("$fromVersion") must be older than target version ("$resolvedVersion").',
          suggestion:
              'Supply a fromVersion that is older than the target version, or omit fromVersion.',
          details: {'fromVersion': fromVersion, 'version': resolvedVersion},
        ),
      );
    }

    return _success(
      entries.sublist(targetIndex, boundaryIdx).take(versionLimit).toList(),
      package,
      resolvedVersion,
    );
  }

  // ── Version comparison ─────────────────────────────────────────────────────

  /// Returns `true` when [entryVersion] matches the major.minor.patch of [target].
  static bool _matchesVersion(String entryVersion, String target) {
    if (entryVersion == target) return true;
    final eParts = _versionParts(entryVersion);
    final tParts = _versionParts(target);
    return eParts[0] == tParts[0] && eParts[1] == tParts[1] && eParts[2] == tParts[2];
  }

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

  static CallToolResult _success(
    List<ChangelogEntry> entries,
    String package,
    String resolvedVersion,
  ) =>
      ToolResponse.ok(
        {
          'package': package,
          'entries': entries.map(_entryToJson).toList(),
        },
        resolvedVersion: resolvedVersion,
      );

  static Map<String, Object?> _entryToJson(ChangelogEntry e) => {
    'version': e.version,
    if (e.date case final d?) 'date': d.toIso8601String(),
    'changes': e.changes,
    'rawText': e.rawText,
    'breaking': e.breaking,
  };
}
