/// Handler for the `list_package_source_files` MCP tool.
///
/// Returns the list of file paths available in a pub.dev package tarball.
/// Shares the `source:<name>:<version>` cache entry with
/// `GetPackageSourceFileHandler` — once the tarball is warm, listing is free.
library;

import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../cache/memory_cache.dart';
import '../data/domain_error.dart';
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
    switch (await _loadSourceFiles(name, resolvedVersion)) {
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

  Future<PubDevResult<Map<String, String>>> _loadSourceFiles(
    String name,
    String version,
  ) async {
    final cacheKey = 'source:$name:$version';
    final cached = _cache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'list_package_source_files: cache hit key=$cacheKey');
      try {
        return PubDevSuccess(await cached);
      } on Object {
        // The in-flight request that was sharing this future failed; fall
        // through to issue an independent request.
      }
    }

    _log(LoggingLevel.debug, 'list_package_source_files: cache miss key=$cacheKey');
    _log(LoggingLevel.info, 'list_package_source_files: HTTP tarball request name=$name');

    // Store the in-flight future before awaiting so that concurrent callers for
    // the same key share this single download instead of issuing duplicates
    // (cache-stampede prevention, as required by ResponseCache's contract).
    final completer = Completer<Map<String, String>>();
    _cache.set(cacheKey, completer.future, kSourceFileTtl);

    switch (await _client.getPackageSourceFiles(name, version)) {
      case PubDevSuccess(:final value):
        completer.complete(value);
        return PubDevSuccess(value);
      case PubDevFailure(:final error):
        // Unblock any concurrent waiters with an error, then evict the entry so
        // the next independent request gets a clean miss.
        // `ignore()` registers a no-op error handler so Dart does not report an
        // unhandled Future error when no concurrent caller is actually waiting.
        completer.future.ignore();
        completer.completeError(StateError('fetch failed: ${error.code}'));
        _cache.invalidate(cacheKey);
        return PubDevFailure(
          error.code == DomainErrors.packageNotFound
              ? DomainError(
                  code: DomainErrors.packageNotFound,
                  message: 'Package "$name" not found on pub.dev.',
                  suggestion: 'Verify the package name and try again.',
                )
              : error,
        );
    }
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
