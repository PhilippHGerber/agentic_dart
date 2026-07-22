/// Handler for the `get_security_advisories` MCP tool.
///
/// Returns every published `SecurityAdvisory` for a package, split into
/// `affecting` (advisories whose OSV ranges cover the Resolved Version) and
/// `other` (advisories on the package that do not affect it) — a
/// version-aware answer, not a raw dump. See
/// `issues/fr-tools-disposition/02-security-advisories-tool.md`.
library;

import 'package:dart_mcp/server.dart';

import '../cache/cache_registry.dart';
import '../cache/keyed_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import '../data/osv_range_evaluator.dart';
import 'tool_response.dart';
import 'version_resolver.dart';

/// Handles calls to the `get_security_advisories` MCP tool.
///
/// Resolves the full advisory list through the shared `securityAdvisories`
/// [KeyedCache] facade (from `CacheRegistry`), keyed by package `name` only —
/// pub.dev's advisories endpoint is not version-scoped, so one cached fetch
/// serves every `version` a caller supplies. The Resolved Version is checked
/// against each advisory's OSV ranges (`osvRangesAffectVersion`) on every
/// call, cache hit or miss, so a cached list still splits correctly per
/// caller-supplied version.
final class GetSecurityAdvisoriesHandler {
  /// Creates a [GetSecurityAdvisoriesHandler].
  ///
  /// [versionResolver] resolves the Resolved Version, falling back to the
  /// Latest Stable Version when the caller omits one. [securityAdvisories] is
  /// the shared [KeyedCache] facade (from `CacheRegistry`) that resolves and
  /// caches the full advisory list by [SecurityAdvisoriesId]. [log] receives
  /// structured log events at the appropriate [LoggingLevel].
  const GetSecurityAdvisoriesHandler({
    required VersionResolver versionResolver,
    required KeyedCache<SecurityAdvisoriesId, List<SecurityAdvisory>> securityAdvisories,
    required void Function(LoggingLevel, Object) log,
  }) : _versionResolver = versionResolver,
       _securityAdvisories = securityAdvisories,
       _log = log;

  final VersionResolver _versionResolver;
  final KeyedCache<SecurityAdvisoriesId, List<SecurityAdvisory>> _securityAdvisories;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `get_security_advisories`.
  ///
  /// Resolves the version (via [VersionResolver] when absent), then resolves
  /// the full advisory list through `securityAdvisories`. Every advisory is
  /// evaluated against the Resolved Version and bucketed into `affecting` /
  /// `other`. A package with zero advisories succeeds with both lists empty.
  /// Returns [CallToolResult.isError] `true` on any domain failure.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final package = (args['package'] as String?) ?? '';
    final suppliedVersion = args['version'] as String?;

    _log(
      LoggingLevel.info,
      'get_security_advisories: package=$package'
      '${suppliedVersion != null ? ' version=$suppliedVersion' : ''}',
    );

    // ── Resolve version ────────────────────────────────────────────────────────

    final String resolvedVersion;
    switch (await _versionResolver.resolve(
      package: package,
      supplied: suppliedVersion,
      tool: 'get_security_advisories',
    )) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        resolvedVersion = value;
    }

    // ── Resolve advisory list ──────────────────────────────────────────────────

    final List<SecurityAdvisory> advisories;
    switch (await _securityAdvisories.resolve((name: package))) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        advisories = value;
    }

    // ── Evaluate against the resolved version ──────────────────────────────────

    final affecting = <SecurityAdvisory>[];
    final other = <SecurityAdvisory>[];
    for (final advisory in advisories) {
      if (osvRangesAffectVersion(advisory.ranges, resolvedVersion)) {
        affecting.add(advisory);
      } else {
        other.add(advisory);
      }
    }

    return ToolResponse.ok(
      {
        'affecting': affecting.map(_advisoryToJson).toList(),
        'other': other.map(_advisoryToJson).toList(),
      },
      resolvedVersion: resolvedVersion,
    );
  }

  // ── Serialisation ──────────────────────────────────────────────────────────

  static Map<String, Object?> _advisoryToJson(SecurityAdvisory a) => {
    'id': a.id,
    'aliases': a.aliases,
    'summary': a.summary,
    'url': a.url,
    'affectedRanges': a.ranges.map(_rangeToJson).toList(),
  };

  static Map<String, Object?> _rangeToJson(OsvRange r) => {
    'events': r.events.map(_eventToJson).toList(),
  };

  static Map<String, Object?> _eventToJson(OsvEvent e) => {
    if (e.introduced != null) 'introduced': e.introduced,
    if (e.fixed != null) 'fixed': e.fixed,
    if (e.lastAffected != null) 'lastAffected': e.lastAffected,
    if (e.limit != null) 'limit': e.limit,
  };
}
