/// Handler for the `list_package_source_files` MCP tool.
///
/// Returns the list of file paths available in a pub.dev package tarball.
/// Shares the `sourceFiles` [KeyedCache] facade (from `CacheRegistry`) with
/// `get_source_slice`, `get_throw_statements`, and the `pubspec` package
/// resource — once the tarball is warm, listing is free.
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../cache/cache_registry.dart';
import '../cache/keyed_cache.dart';
import '../data/domain_error.dart';
import '../data/pub_client.dart';

/// Handles calls to the `list_package_source_files` MCP tool.
final class ListPackageSourceFilesHandler {
  /// Creates a [ListPackageSourceFilesHandler].
  ///
  /// [sourceFiles] is the shared [KeyedCache] facade (from `CacheRegistry`) —
  /// pass the same instance used by `GetSourceSliceHandler` and
  /// `GetThrowStatementsHandler` so all three share the tarball download.
  const ListPackageSourceFilesHandler({
    required PubDevClient client,
    required KeyedCache<SourceFilesId, Map<String, String>> sourceFiles,
    required void Function(LoggingLevel, Object) log,
  }) : _client = client,
       _sourceFiles = sourceFiles,
       _log = log;

  final PubDevClient _client;
  final KeyedCache<SourceFilesId, Map<String, String>> _sourceFiles;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `list_package_source_files`.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final name = (args['name'] as String?) ?? '';
    final suppliedVersion = args['version'] as String?;
    final rawDirectory = args['directory'] as String?;
    final fileExtension = args['fileExtension'] as String?;

    // ── Resolve version ────────────────────────────────────────────────────────

    final String resolvedVersion;
    if (suppliedVersion != null) {
      resolvedVersion = suppliedVersion;
    } else {
      _log(
        LoggingLevel.info,
        'list_package_source_files: resolving latest stable version for $name',
      );
      switch (await _client.resolveLatestStable(name)) {
        case PubDevFailure(:final error):
          return _domainError(error);
        case PubDevSuccess(:final value):
          resolvedVersion = value;
      }
      _log(LoggingLevel.debug, 'list_package_source_files: resolved version=$resolvedVersion');
    }

    _log(
      LoggingLevel.info,
      'list_package_source_files: name=$name version=$resolvedVersion'
      '${rawDirectory != null ? ' directory=$rawDirectory' : ''}'
      '${fileExtension != null ? ' ext=$fileExtension' : ''}',
    );

    final Map<String, String> files;
    switch (await _sourceFiles.resolve((name: name, version: resolvedVersion))) {
      case PubDevFailure(:final error):
        return _domainError(error);
      case PubDevSuccess(:final value):
        files = value;
    }

    final directory = _normalizeDirectory(rawDirectory);
    var paths = files.keys.toList();

    if (directory != null && directory.isNotEmpty) {
      paths = paths.where((p) => p.startsWith(directory)).toList();
    }
    if (fileExtension != null && fileExtension.isNotEmpty) {
      paths = paths.where((p) => p.endsWith(fileExtension)).toList();
    }

    paths.sort();
    return CallToolResult(
      content: [
        TextContent(
          text: jsonEncode({
            'resolvedVersion': resolvedVersion,
            'name': name,
            'files': paths,
          }),
        ),
      ],
    );
  }

  static String? _normalizeDirectory(String? raw) {
    if (raw == null) return null;
    var dir = raw.startsWith('/') ? raw.substring(1) : raw;
    if (!dir.endsWith('/') && dir.isNotEmpty) dir = '$dir/';
    return dir;
  }

  static CallToolResult _domainError(DomainError error) => CallToolResult(
    content: [TextContent(text: jsonEncode(error.toJson()))],
    isError: true,
  );
}
