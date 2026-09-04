/// Handler for the `get_sdk_release_notes` MCP tool.
library;

import 'package:dart_mcp/server.dart';

import '../cache/cache_registry.dart';
import '../cache/keyed_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import 'tool_response.dart';

final _kNonNumericSuffix = RegExp('[^0-9].*');

/// Handles calls to the `get_sdk_release_notes` MCP tool.
final class GetSdkReleaseNotesHandler {
  /// Creates a [GetSdkReleaseNotesHandler].
  const GetSdkReleaseNotesHandler({
    required KeyedCache<SdkChangelogId, List<SdkReleaseNotesEntry>> sdkChangelog,
    required void Function(LoggingLevel, Object) log,
  }) : _sdkChangelog = sdkChangelog,
       _log = log;

  final KeyedCache<SdkChangelogId, List<SdkReleaseNotesEntry>> _sdkChangelog;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `get_sdk_release_notes`.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final sdk = args['sdk'] as String?;
    final version = args['version'] as String?;
    final fromVersion = args['fromVersion'] as String?;
    final limit = args['limit'] as int?;

    if (sdk == null || (sdk != 'dart' && sdk != 'flutter')) {
      return ToolResponse.error(
        DomainError(
          code: DomainErrors.invalidArgument,
          message: 'Invalid sdk parameter: "$sdk". Must be "dart" or "flutter".',
          suggestion: 'Specify sdk as either "dart" or "flutter".',
          details: {'sdk': sdk},
        ),
      );
    }

    if (limit != null && limit <= 0) {
      return ToolResponse.error(
        const DomainError(
          code: DomainErrors.invalidArgument,
          message: 'limit must be greater than zero.',
          suggestion: 'Provide a positive integer for limit.',
        ),
      );
    }

    final effectiveLimit = limit ?? (fromVersion != null ? 5 : 1);

    _log(
      LoggingLevel.info,
      'get_sdk_release_notes: sdk=$sdk'
      '${version != null ? ' version=$version' : ''}'
      '${fromVersion != null ? ' fromVersion=$fromVersion' : ''}'
      ' limit=$effectiveLimit',
    );

    final List<SdkReleaseNotesEntry> entries;
    switch (await _sdkChangelog.resolve((sdk: sdk, version: version))) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        entries = value;
    }

    if (entries.isEmpty) {
      return ToolResponse.error(
        DomainError(
          code: DomainErrors.noDocumentation,
          message: 'The $sdk SDK changelog contains no version entries.',
          suggestion: 'Check upstream GitHub repository availability.',
          details: {'sdk': sdk},
        ),
      );
    }

    final int targetIndex;
    final String resolvedVersion;
    if (version == null) {
      targetIndex = 0;
      resolvedVersion = entries.first.version;
    } else {
      targetIndex = entries.indexWhere((e) => _matchesVersion(e.version, version));
      if (targetIndex < 0) {
        return ToolResponse.error(
          DomainError(
            code: DomainErrors.sdkVersionNotFound,
            message: 'No $sdk SDK release matches version "$version".',
            suggestion: 'Verify the version string exists in the $sdk SDK changelog.',
            details: {'sdk': sdk},
          ),
        );
      }
      resolvedVersion = entries[targetIndex].version;
    }

    if (fromVersion == null) {
      final bounded = entries.sublist(targetIndex).take(effectiveLimit).toList();
      return _success(bounded, sdk, resolvedVersion);
    }

    return _applyFromVersion(
      entries: entries,
      sdk: sdk,
      targetIndex: targetIndex,
      effectiveLimit: effectiveLimit,
      fromVersion: fromVersion,
      resolvedVersion: resolvedVersion,
    );
  }

  static CallToolResult _applyFromVersion({
    required List<SdkReleaseNotesEntry> entries,
    required String sdk,
    required int targetIndex,
    required int effectiveLimit,
    required String fromVersion,
    required String resolvedVersion,
  }) {
    var fromIndex = entries.indexWhere((e) => _matchesVersion(e.version, fromVersion));

    if (fromIndex < 0) {
      fromIndex = entries.indexWhere((e) => _isOlder(e.version, fromVersion));
      if (fromIndex < 0) {
        return ToolResponse.error(
          DomainError(
            code: DomainErrors.sdkVersionNotFound,
            message:
                'fromVersion "$fromVersion" was not found and is older than all entries in the $sdk SDK changelog.',
            suggestion:
                'Supply a fromVersion that appears in the changelog, or omit it to retrieve recent entries.',
            details: {'sdk': sdk},
          ),
        );
      }
    }

    if (fromIndex <= targetIndex) {
      return ToolResponse.error(
        DomainError(
          code: DomainErrors.invalidArgument,
          message:
              'fromVersion ("$fromVersion") must be older than target version ("$resolvedVersion").',
          suggestion: 'Ensure fromVersion is strictly older than version, or omit fromVersion.',
          details: {'sdk': sdk},
        ),
      );
    }

    final bounded = entries.sublist(targetIndex, fromIndex).take(effectiveLimit).toList();
    return _success(bounded, sdk, resolvedVersion);
  }

  static bool _matchesVersion(String entryVersion, String targetVersion) {
    if (entryVersion == targetVersion) return true;
    final eParts = _versionParts(entryVersion);
    final tParts = _versionParts(targetVersion);
    for (var i = 0; i < 3; i++) {
      if (eParts[i] != tParts[i]) return false;
    }
    return true;
  }

  static bool _isOlder(String v, String target) {
    final vParts = _versionParts(v);
    final tParts = _versionParts(target);
    for (var i = 0; i < 3; i++) {
      final cmp = vParts[i].compareTo(tParts[i]);
      if (cmp != 0) return cmp < 0;
    }
    return false;
  }

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

  static CallToolResult _success(
    List<SdkReleaseNotesEntry> entries,
    String sdk,
    String resolvedVersion,
  ) => ToolResponse.ok(
    {
      'sdk': sdk,
      'entries': entries.map(_entryToJson).toList(),
    },
    resolvedVersion: resolvedVersion,
  );

  static Map<String, Object?> _entryToJson(SdkReleaseNotesEntry e) => {
    'version': e.version,
    if (e.date case final d?) 'date': d.toIso8601String(),
    'changes': e.changes,
    'sections': e.sections,
    'breaking': e.breaking,
  };
}
