/// Handler for the `list_package_versions` MCP tool.
///
/// Returns every published version of a package, bucketed into `stable`,
/// `prerelease`, and `retracted` lists. Each bucket is sorted newest-first by
/// publish date. Each entry carries the version string and its `publishedAt`
/// date. Version-level retraction comes from the pub.dev API; package-level
/// discontinuation is out of scope (it belongs on `get_package`).
///
/// This tool takes no `version` parameter and therefore emits no
/// `resolvedVersion` field.
///
/// See `issues/pubdev-context-v1/06-list-package-versions.md`.
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../cache/memory_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import '../data/pub_client.dart';

/// Cache-key prefix for the full published-version list of a package.
///
/// Full key format: `$kVersionsCachePrefix:<packageName>`. Shared with the
/// server completion handler so `{version}` autocompletion can read the same
/// cache this tool warms.
const kVersionsCachePrefix = 'versions';

// ─── Domain error constants ───────────────────────────────────────────────────

const _missingName = DomainError(
  code: DomainErrors.invalidArgument,
  message: 'name must be a non-empty package name.',
  suggestion: 'Provide the package name as the name argument.',
);

// ─── Handler ──────────────────────────────────────────────────────────────────

/// Handles calls to the `list_package_versions` MCP tool.
///
/// Consults the cache before issuing HTTP requests; stores the full parsed
/// [PackageVersion] list under [kPackageVersionsTtl] so repeat calls are served
/// without a network round-trip. HTTP failures are not cached so transient
/// errors can be retried.
final class ListPackageVersionsHandler {
  /// Creates a [ListPackageVersionsHandler].
  ///
  /// [client] is the pub.dev HTTP gateway. [cache] holds the full unbucketed
  /// version list keyed by package name. [log] receives structured log events
  /// at the appropriate [LoggingLevel].
  const ListPackageVersionsHandler({
    required PubDevClient client,
    required ResponseCache<List<PackageVersion>> cache,
    required void Function(LoggingLevel, Object) log,
  }) : _client = client,
       _cache = cache,
       _log = log;

  final PubDevClient _client;
  final ResponseCache<List<PackageVersion>> _cache;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `list_package_versions`.
  ///
  /// Fetches the version list from cache or pub.dev, buckets it into
  /// `stable` / `prerelease` / `retracted`, and returns each bucket sorted
  /// newest-first. Returns [CallToolResult.isError] `true` on any domain
  /// failure — including [DomainErrors.packageNotFound] for unknown packages.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final name = (args['name'] as String?) ?? '';

    if (name.isEmpty) return _domainError(_missingName);

    _log(LoggingLevel.info, 'list_package_versions: name=$name');

    final cacheKey = '$kVersionsCachePrefix:$name';
    final cached = _cache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'list_package_versions: cache hit key=$cacheKey');
      return _success(name, await cached);
    }

    _log(LoggingLevel.debug, 'list_package_versions: cache miss key=$cacheKey');
    _log(LoggingLevel.info, 'list_package_versions: HTTP request name=$name');

    switch (await _client.listVersions(name)) {
      case PubDevFailure(:final error):
        _log(
          LoggingLevel.warning,
          'list_package_versions: failed name=$name error=${error.code}',
        );
        return _domainError(error);
      case PubDevSuccess(:final value):
        _cache.set(cacheKey, Future.value(value), kPackageVersionsTtl);
        return _success(name, value);
    }
  }

  // ── Bucketing & sorting ──────────────────────────────────────────────────────

  /// Buckets [versions] and serialises the response.
  ///
  /// A retracted version lands in `retracted` regardless of whether its semver
  /// is stable or a pre-release; retraction takes precedence so callers never
  /// treat a withdrawn version as installable. Non-retracted pre-releases go to
  /// `prerelease`; everything else is `stable`. Each bucket is sorted
  /// newest-first by publish date.
  static CallToolResult _success(String name, List<PackageVersion> versions) {
    final stable = <PackageVersion>[];
    final prerelease = <PackageVersion>[];
    final retracted = <PackageVersion>[];

    for (final v in versions) {
      if (v.retracted) {
        retracted.add(v);
      } else if (v.isPrerelease) {
        prerelease.add(v);
      } else {
        stable.add(v);
      }
    }

    _sortNewestFirst(stable);
    _sortNewestFirst(prerelease);
    _sortNewestFirst(retracted);

    return CallToolResult(
      content: [
        TextContent(
          text: jsonEncode({
            'package': name,
            'stable': stable.map(_toJson).toList(),
            'prerelease': prerelease.map(_toJson).toList(),
            'retracted': retracted.map(_toJson).toList(),
          }),
        ),
      ],
    );
  }

  /// Sorts [list] newest-first by [PackageVersion.publishedAt].
  ///
  /// Entries with a `null` publish date sort last, preserving a deterministic
  /// order even when pub.dev omits the timestamp.
  static void _sortNewestFirst(List<PackageVersion> list) {
    list.sort((a, b) {
      final ad = a.publishedAt;
      final bd = b.publishedAt;
      if (ad == null && bd == null) return 0;
      if (ad == null) return 1;
      if (bd == null) return -1;
      return bd.compareTo(ad);
    });
  }

  // ── Serialisation ──────────────────────────────────────────────────────────

  static Map<String, Object?> _toJson(PackageVersion v) => {
    'version': v.version,
    if (v.publishedAt case final d?) 'publishedAt': d.toIso8601String(),
  };

  static CallToolResult _domainError(DomainError error) => CallToolResult(
    content: [TextContent(text: error.toJsonString())],
    isError: true,
  );
}
