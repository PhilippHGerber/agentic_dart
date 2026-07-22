/// Shared best-effort security-advisories fetch for the passive signal on
/// `get_package` and `compare_packages`.
///
/// See `issues/fr-tools-disposition/03-advisories-passive-signal.md`.
library;

import 'package:dart_mcp/server.dart';

import '../cache/cache_registry.dart';
import '../cache/keyed_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';

/// Resolves [package]'s advisory list through [cache] and maps a success to
/// [onSuccess]. Returns `null` on any failure — a [PubDevFailure] from [cache]
/// or an exception escaping the fetch — logging a warning tagged with [tool]
/// via [log] rather than letting the failure propagate. The caller's tool
/// call is expected to treat a `null` result as "omit this best-effort
/// signal," never as a reason to fail.
Future<T?> fetchAdvisoriesBestEffort<T>({
  required KeyedCache<SecurityAdvisoriesId, List<SecurityAdvisory>> cache,
  required String package,
  required String tool,
  required void Function(LoggingLevel, Object) log,
  required T Function(List<SecurityAdvisory> advisories) onSuccess,
}) async {
  try {
    final result = await cache.resolve((name: package));
    return switch (result) {
      PubDevFailure() => null,
      PubDevSuccess(:final value) => onSuccess(value),
    };
  } on Object catch (error) {
    log(
      LoggingLevel.warning,
      '$tool: advisories fetch failed package=$package error=$error',
    );
    return null;
  }
}
