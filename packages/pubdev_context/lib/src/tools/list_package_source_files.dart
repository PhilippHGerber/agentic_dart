/// Handler for the `list_package_source_files` MCP tool.
///
/// Returns the list of file paths available in a pub.dev package tarball.
/// Shares the `source:<name>:<version>` cache entry with
/// `GetPackageSourceFileHandler` — once the tarball is warm, listing is free.
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../cache/memory_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import '../data/pub_client.dart';

/// Handles calls to the `list_package_source_files` MCP tool.
final class ListPackageSourceFilesHandler {
  /// Creates a [ListPackageSourceFilesHandler].
  const ListPackageSourceFilesHandler({
    required PubDevClient client,
    required ResponseCache<Map<String, String>> cache,
    required void Function(LoggingLevel, Object) log,
  }) : _client = client,
       _cache = cache,
       _log = log;

  final PubDevClient _client;
  final ResponseCache<Map<String, String>> _cache;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `list_package_source_files`.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final name = (args['name'] as String?) ?? '';
    final rawVersion = args['version'] as String?;
    final rawDirectory = args['directory'] as String?;
    final fileExtension = args['fileExtension'] as String?;

    final String version;
    if (rawVersion != null) {
      version = rawVersion;
    } else {
      _log(LoggingLevel.info, 'list_package_source_files: resolving latest version for $name');
      final packageResult = await _client.getPackage(name);
      if (packageResult case PubDevFailure(:final error)) {
        return _domainError(error);
      }
      version = (packageResult as PubDevSuccess<PackageDetail>).value.version;
    }

    _log(
      LoggingLevel.info,
      'list_package_source_files: name=$name version=$version'
      '${rawDirectory != null ? ' directory=$rawDirectory' : ''}'
      '${fileExtension != null ? ' ext=$fileExtension' : ''}',
    );

    final files = await _loadSourceFiles(name, version);
    if (files == null) {
      return _domainError(
        DomainError(
          code: DomainErrors.packageNotFound,
          message: 'Package "$name" not found on pub.dev.',
          suggestion: 'Verify the package name and try again.',
        ),
      );
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
            'name': name,
            'version': version,
            'files': paths,
          }),
        ),
      ],
    );
  }

  Future<Map<String, String>?> _loadSourceFiles(String name, String version) async {
    final cacheKey = 'source:$name:$version';
    final cached = _cache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'list_package_source_files: cache hit key=$cacheKey');
      return cached;
    }

    _log(LoggingLevel.debug, 'list_package_source_files: cache miss key=$cacheKey');
    _log(LoggingLevel.info, 'list_package_source_files: HTTP tarball request name=$name');

    // Store the in-flight future before awaiting to prevent cache stampedes.
    final fetchFuture = _client.getPackageSourceFiles(name, version);
    _cache.set(
      cacheKey,
      fetchFuture.then((r) => r is PubDevSuccess<Map<String, String>> ? r.value : {}),
      kSourceFileTtl,
    );

    final result = await fetchFuture;
    if (result case PubDevSuccess(:final value)) {
      _cache.set(cacheKey, Future.value(value), kSourceFileTtl);
      return value;
    }
    _cache.invalidate(cacheKey);
    return null;
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
