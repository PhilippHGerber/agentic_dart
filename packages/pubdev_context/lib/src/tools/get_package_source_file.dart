/// Handler for the `get_package_source_file` MCP tool.
///
/// Returns the content of a single source file from a pub.dev package tarball.
/// The tarball is downloaded once, fully extracted, and stored in the shared
/// source-files cache keyed as `source:<name>:<version>` with a [kSourceFileTtl]
/// TTL. Subsequent calls for any file in the same package version are served
/// from cache without additional HTTP requests.
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../cache/memory_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import '../data/pub_client.dart';

/// Handles calls to the `get_package_source_file` MCP tool.
final class GetPackageSourceFileHandler {
  /// Creates a [GetPackageSourceFileHandler].
  const GetPackageSourceFileHandler({
    required PubDevClient client,
    required ResponseCache<Map<String, String>> cache,
    required void Function(LoggingLevel, Object) log,
  }) : _client = client,
       _cache = cache,
       _log = log;

  final PubDevClient _client;
  final ResponseCache<Map<String, String>> _cache;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `get_package_source_file`.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final name = (args['name'] as String?) ?? '';
    final rawVersion = args['version'] as String?;
    final rawPath = (args['path'] as String?) ?? '';

    final path = _normalizePath(rawPath);
    if (path == null) {
      return _domainError(
        const DomainError(
          error: DomainErrors.invalidInput,
          message: 'Path contains invalid segments.',
          suggestion:
              'Use a relative path without ".." components '
              '(e.g. "lib/src/server/prompts_support.dart").',
        ),
      );
    }

    final String version;
    if (rawVersion != null) {
      version = rawVersion;
    } else {
      _log(LoggingLevel.info, 'get_package_source_file: resolving latest version for $name');
      final packageResult = await _client.getPackage(name);
      if (packageResult case PubDevFailure(:final error)) {
        return _domainError(error);
      }
      version = (packageResult as PubDevSuccess<PackageDetail>).value.version;
    }

    _log(
      LoggingLevel.info,
      'get_package_source_file: name=$name version=$version path=$path',
    );

    final files = await _loadSourceFiles(name, version);
    if (files == null) return _domainError(_notFoundError(name));

    final content = files[path];
    if (content == null) {
      final suggestion = _closestMatchSuggestion(path, files.keys);
      return _domainError(
        DomainError(
          error: DomainErrors.sourceFileNotFound,
          message: 'Source file "$path" not found in $name $version.',
          suggestion: suggestion,
        ),
      );
    }

    return CallToolResult(content: [TextContent(text: content)]);
  }

  Future<Map<String, String>?> _loadSourceFiles(String name, String version) async {
    final cacheKey = 'source:$name:$version';
    final cached = _cache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'get_package_source_file: cache hit key=$cacheKey');
      return cached;
    }

    _log(LoggingLevel.debug, 'get_package_source_file: cache miss key=$cacheKey');
    _log(LoggingLevel.info, 'get_package_source_file: HTTP tarball request name=$name');

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

  static String? _normalizePath(String raw) {
    final stripped = raw.startsWith('/') ? raw.substring(1) : raw;
    final segments = stripped.split('/');
    if (segments.any((s) => s == '..')) return null;
    return segments.join('/');
  }

  static String _closestMatchSuggestion(String path, Iterable<String> keys) {
    final filename = path.split('/').last.toLowerCase();
    final matches = keys.where((k) => k.split('/').last.toLowerCase() == filename).toList();
    if (matches.isNotEmpty) {
      final quoted = matches.take(3).map((p) => '"$p"').join(', ');
      return 'Did you mean: $quoted?';
    }
    return 'Call list_package_source_files to browse available paths.';
  }

  static DomainError _notFoundError(String name) => DomainError(
    error: DomainErrors.packageNotFound,
    message: 'Package "$name" not found on pub.dev.',
    suggestion: 'Verify the package name and try again.',
  );

  static CallToolResult _domainError(DomainError error) => CallToolResult(
    content: [TextContent(text: jsonEncode(error.toJson()))],
    isError: true,
  );
}
