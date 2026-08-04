/// Handler for the `list_package_source_files` MCP tool.
///
/// Returns the list of file paths available in a pub.dev package tarball.
/// Shares the `sourceFiles` [KeyedCache] facade (from `CacheRegistry`) with
/// `get_source_slice`, `get_throw_statements`, and the `pubspec` package
/// resource — once the tarball is warm, listing is free.
library;

import 'package:dart_mcp/server.dart';

import '../cache/cache_registry.dart';
import '../cache/keyed_cache.dart';
import '../data/domain_error.dart';
import 'path_filters.dart';
import 'sdk_package_guard.dart';
import 'tool_response.dart';
import 'version_resolver.dart';

/// Handles calls to the `list_package_source_files` MCP tool.
final class ListPackageSourceFilesHandler {
  /// Creates a [ListPackageSourceFilesHandler].
  ///
  /// [versionResolver] resolves the Resolved Version, falling back to the
  /// Latest Stable Version when the caller omits one. [sourceFiles] is the
  /// shared [KeyedCache] facade (from `CacheRegistry`) — pass the same
  /// instance used by `GetSourceSliceHandler` and `GetThrowStatementsHandler`
  /// so all three share the tarball download.
  const ListPackageSourceFilesHandler({
    required VersionResolver versionResolver,
    required KeyedCache<SourceFilesId, Map<String, String>> sourceFiles,
    required void Function(LoggingLevel, Object) log,
  }) : _versionResolver = versionResolver,
       _sourceFiles = sourceFiles,
       _log = log;

  final VersionResolver _versionResolver;
  final KeyedCache<SourceFilesId, Map<String, String>> _sourceFiles;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `list_package_source_files`.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final package = (args['package'] as String?) ?? '';
    final suppliedVersion = args['version'] as String?;
    final rawDirectory = args['directory'] as String?;
    final fileExtension = args['fileExtension'] as String?;

    // Checked before anything else — including an explicit `version` — so an
    // SDK package name (e.g. "flutter") never reaches VersionResolver/PubDevClient.
    if (sdkPackageGuardError(package) case final error?) return ToolResponse.error(error);

    // ── Resolve version ────────────────────────────────────────────────────────

    final String resolvedVersion;
    switch (await _versionResolver.resolve(
      package: package,
      supplied: suppliedVersion,
      tool: 'list_package_source_files',
    )) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        resolvedVersion = value;
    }

    _log(
      LoggingLevel.info,
      'list_package_source_files: package=$package version=$resolvedVersion'
      '${rawDirectory != null ? ' directory=$rawDirectory' : ''}'
      '${fileExtension != null ? ' ext=$fileExtension' : ''}',
    );

    final Map<String, String> files;
    switch (await _sourceFiles.resolve((name: package, version: resolvedVersion))) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        files = value;
    }

    var paths = files.keys.toList();

    paths = paths.where((p) => matchesDirectoryFilter(p, rawDirectory)).toList();
    if (fileExtension != null && fileExtension.isNotEmpty) {
      paths = paths.where((p) => p.endsWith(fileExtension)).toList();
    }

    paths.sort();
    return ToolResponse.ok({'name': package, 'files': paths}, resolvedVersion: resolvedVersion);
  }
}
