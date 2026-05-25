/// Handler for the `get_package_source_file` MCP tool.
///
/// Returns the content of a single source file from a pub.dev package tarball.
/// The tarball is downloaded once, fully extracted, and stored in the shared
/// source-files cache keyed as `source:<name>:<version>` with a [kSourceFileTtl]
/// TTL. Subsequent calls for any file in the same package version are served
/// from cache without additional HTTP requests.
library;

import 'dart:async';
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
          code: DomainErrors.invalidArgument,
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

    final filesResult = await _loadSourceFiles(name, version);
    if (filesResult case PubDevFailure(:final error)) {
      return _domainError(error);
    }
    final files = (filesResult as PubDevSuccess<Map<String, String>>).value;

    final content = files[path];
    if (content == null) {
      final suggestion = _closestMatchSuggestion(path, files.keys);
      return _domainError(
        DomainError(
          code: DomainErrors.sourceFileNotFound,
          message: 'Source file "$path" not found in $name $version.',
          suggestion: suggestion,
        ),
      );
    }

    return CallToolResult(content: [TextContent(text: content)]);
  }

  Future<PubDevResult<Map<String, String>>> _loadSourceFiles(
    String name,
    String version,
  ) async {
    final cacheKey = 'source:$name:$version';
    final cached = _cache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'get_package_source_file: cache hit key=$cacheKey');
      try {
        return PubDevSuccess(await cached);
      } on Object {
        // The in-flight request that was sharing this future failed; fall
        // through to issue an independent request.
      }
    }

    _log(LoggingLevel.debug, 'get_package_source_file: cache miss key=$cacheKey');
    _log(LoggingLevel.info, 'get_package_source_file: HTTP tarball request name=$name');

    // Store the in-flight future before awaiting so that concurrent callers for
    // the same key share this single download instead of issuing duplicates
    // (cache-stampede prevention, as required by ResponseCache's contract).
    final completer = Completer<Map<String, String>>();
    _cache.set(cacheKey, completer.future, kSourceFileTtl);

    final result = await _client.getPackageSourceFiles(name, version);
    if (result case PubDevSuccess(:final value)) {
      completer.complete(value);
      return PubDevSuccess(value);
    }

    final error = (result as PubDevFailure<Map<String, String>>).error;
    // Unblock any concurrent waiters with an error, then evict the entry so
    // the next independent request gets a clean miss.
    // `ignore()` registers a no-op error handler so Dart does not report an
    // unhandled Future error when no concurrent caller is actually waiting.
    completer.future.ignore();
    completer.completeError(StateError('fetch failed: ${error.code}'));
    _cache.invalidate(cacheKey);
    return PubDevFailure(
      error.code == DomainErrors.packageNotFound ? _notFoundError(name) : error,
    );
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
    code: DomainErrors.packageNotFound,
    message: 'Package "$name" not found on pub.dev.',
    suggestion: 'Verify the package name and try again.',
  );

  static CallToolResult _domainError(DomainError error) => CallToolResult(
    content: [TextContent(text: jsonEncode(error.toJson()))],
    isError: true,
  );
}
