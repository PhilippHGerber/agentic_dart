/// Handler for the `compare_packages` MCP tool.
///
/// [ComparePackagesHandler] compares 2–5 packages side by side, returning a
/// [_ComparisonMatrix]. Packages are fetched using the shared package-metadata
/// cache (same key format as `GetPackageHandler`) so prior `get_package` calls
/// are served from cache at no extra cost. Requests for uncached packages are
/// issued strictly sequentially with a [_kInterRequestDelay] gap to avoid
/// triggering pub.dev rate limits.
///
/// Domain errors are returned as [CallToolResult] with [CallToolResult.isError]
/// `true` and a structured JSON payload — exceptions are never swallowed
/// silently. When every requested package fails, a single domain error is
/// returned; otherwise failed packages appear in `errors` and are excluded
/// from the matrix.
///
/// See `issues/pub-dev-mcp/08-compare-packages-tool.md`.
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../cache/memory_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import '../data/pub_client.dart';

/// The minimum delay between consecutive pub.dev HTTP requests.
const _kInterRequestDelay = Duration(milliseconds: 100);

/// Handles calls to the `compare_packages` MCP tool.
///
/// Constructor dependencies are [client], [cache], and [log]. The [cache]
/// should be the same [ResponseCache] instance shared with `GetPackageHandler`
/// so that prior `get_package` calls are reused. All packages are fetched
/// sequentially; each consecutive pair is separated by at least
/// [_kInterRequestDelay] to respect pub.dev rate limits.
final class ComparePackagesHandler {
  /// Creates a [ComparePackagesHandler].
  ///
  /// [client] is the pub.dev HTTP gateway. [cache] is the shared TTL store for
  /// [PackageDetail] values (same instance as used by `GetPackageHandler`).
  /// [log] receives structured log events at the appropriate [LoggingLevel].
  const ComparePackagesHandler({
    required PubDevClient client,
    required ResponseCache<PackageDetail> cache,
    required void Function(LoggingLevel, Object) log,
  }) : _client = client,
       _cache = cache,
       _log = log;

  final PubDevClient _client;
  final ResponseCache<PackageDetail> _cache;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `compare_packages`.
  ///
  /// Validates that `names` contains between 2 and 5 entries. Fetches each
  /// package sequentially, pausing [_kInterRequestDelay] between requests.
  /// Returns [CallToolResult.isError] `true` when all packages fail or when
  /// input validation fails.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final names =
        ((args['names'] as List<Object?>?) ?? const []).whereType<String>().toList();

    if (names.length < 2) {
      return _domainError(
        const DomainError(
          error: DomainErrors.invalidInput,
          message: 'names must contain at least 2 package names.',
          suggestion: 'Provide between 2 and 5 package names in the names array.',
        ),
      );
    }
    if (names.length > 5) {
      return _domainError(
        const DomainError(
          error: DomainErrors.invalidInput,
          message: 'names must not exceed 5 package names.',
          suggestion: 'Provide between 2 and 5 package names in the names array.',
        ),
      );
    }

    _log(LoggingLevel.info, 'compare_packages: names=${names.join(',')}');

    final errors = <String, String>{};
    final details = <String, PackageDetail>{};

    for (var i = 0; i < names.length; i++) {
      if (i > 0) await Future<void>.delayed(_kInterRequestDelay);
      final name = names[i];
      final result = await _fetchPackage(name);
      switch (result) {
        case PubDevSuccess(:final value):
          details[name] = value;
        case PubDevFailure(:final error):
          _log(
            LoggingLevel.warning,
            'compare_packages: failed name=$name error=${error.error}',
          );
          errors[name] = error.error;
      }
    }

    if (details.isEmpty) {
      return _domainError(
        const DomainError(
          error: DomainErrors.serviceUnavailable,
          message: 'All requested packages failed to load.',
          suggestion: 'Verify that the package names are correct and retry.',
        ),
      );
    }

    return _success(
      _ComparisonMatrix(
        packages: names,
        errors: errors,
        matrix: _buildMatrix(details),
      ),
    );
  }

  Future<PubDevResult<PackageDetail>> _fetchPackage(String name) async {
    final cacheKey = 'package:$name:';
    final cached = _cache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'compare_packages: cache hit key=$cacheKey');
      return PubDevSuccess(await cached);
    }
    _log(LoggingLevel.debug, 'compare_packages: cache miss key=$cacheKey');
    _log(LoggingLevel.info, 'compare_packages: HTTP request name=$name');
    final result = await _client.getPackage(name);
    if (result case PubDevSuccess(:final value)) {
      _cache.set(cacheKey, Future.value(value), kPackageMetadataTtl);
    }
    return result;
  }

  static Map<String, Map<String, Object?>> _buildMatrix(
    Map<String, PackageDetail> details,
  ) {
    final matrix = <String, Map<String, Object?>>{};
    for (final entry in details.entries) {
      final pkg = entry.key;
      final d = entry.value;
      _set(matrix, 'name', pkg, d.name);
      _set(matrix, 'version', pkg, d.version);
      _set(matrix, 'description', pkg, d.description);
      _set(matrix, 'likes', pkg, d.score.likes);
      _set(matrix, 'pubPoints', pkg, d.score.pubPoints);
      _set(matrix, 'popularity', pkg, d.score.popularity);
      _set(matrix, 'verified', pkg, d.verified);
      _set(matrix, 'platforms', pkg, d.platforms);
      _set(matrix, 'topics', pkg, d.topics);
      _set(matrix, 'isFlutterFavorite', pkg, d.isFlutterFavorite);
      _set(matrix, 'activeMaintenance', pkg, d.activeMaintenance);
      _set(matrix, 'daysSinceUpdate', pkg, _daysSince(d.publishedAt));
      _set(matrix, 'license', pkg, d.license);
      _set(matrix, 'publisher', pkg, d.publisher);
      _set(matrix, 'sdkConstraints.dart', pkg, d.sdkConstraints.dart);
      _set(matrix, 'sdkConstraints.flutter', pkg, d.sdkConstraints.flutter);
      _set(matrix, 'dependencies', pkg, d.dependencies.length);
    }
    return matrix;
  }

  static void _set(
    Map<String, Map<String, Object?>> matrix,
    String field,
    String pkg,
    Object? value,
  ) => (matrix[field] ??= {})[pkg] = value;

  static int _daysSince(DateTime? publishedAt) {
    if (publishedAt == null) return 0;
    return DateTime.now().difference(publishedAt).inDays;
  }

  static CallToolResult _success(_ComparisonMatrix m) =>
      CallToolResult(content: [TextContent(text: jsonEncode(m.toJson()))]);

  static CallToolResult _domainError(DomainError error) => CallToolResult(
    content: [TextContent(text: error.toJsonString())],
    isError: true,
  );
}

/// The result payload of the `compare_packages` tool.
///
/// [packages] lists all requested package names in the original order.
/// [errors] maps each failed package name to its domain error code; it is
/// always present but may be an empty map when all packages succeed.
/// [matrix] maps each field name to a map of package name → value; packages
/// listed in [errors] are excluded from [matrix].
final class _ComparisonMatrix {
  const _ComparisonMatrix({
    required this.packages,
    required this.errors,
    required this.matrix,
  });

  /// All requested package names in request order.
  final List<String> packages;

  /// Maps failed package names to their domain error codes.
  final Map<String, String> errors;

  /// Maps field names to per-package values for all successful packages.
  final Map<String, Map<String, Object?>> matrix;

  /// Returns this matrix as a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'packages': packages,
    'errors': errors,
    'matrix': matrix,
  };
}
