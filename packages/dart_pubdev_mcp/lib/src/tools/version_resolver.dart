/// The Resolved Version dance every version-accepting tool handler performs.
///
/// [VersionResolver] is the single home of the "use the supplied version, else
/// resolve Latest Stable" logic that previously existed as three separately
/// spelled variants across the 9 resolving handlers. It owns the two log lines
/// every handler used to duplicate ("resolving latest stable…", "resolved
/// version=…"), each tagged with the calling `tool`'s name.
///
/// [PubDevClient.resolveLatestStable] is a Package Info Cache hit under
/// ADR-0004 — this module adds no caching of its own.
library;

import 'package:dart_mcp/server.dart';

import '../data/domain_error.dart';
import '../data/pub_client.dart';

/// Resolves the Resolved Version for a tool call: the supplied version when
/// present, otherwise the Latest Stable Version via [PubDevClient.resolveLatestStable].
final class VersionResolver {
  /// Creates a [VersionResolver].
  ///
  /// [client] is the pub.dev HTTP gateway, used only for Latest Stable Version
  /// resolution. [log] receives structured log events at the appropriate
  /// [LoggingLevel].
  const VersionResolver({
    required PubDevClient client,
    required void Function(LoggingLevel, Object) log,
  }) : _client = client,
       _log = log;

  final PubDevClient _client;
  final void Function(LoggingLevel, Object) _log;

  /// Resolves the version to use for a call to [tool] against [package].
  ///
  /// Returns [supplied] immediately, wrapped in [PubDevSuccess], without
  /// calling the client. When [supplied] is `null`, resolves the Latest Stable
  /// Version via [PubDevClient.resolveLatestStable], logging the resolving and
  /// resolved lines tagged with [tool]. A resolution failure is passed through
  /// unchanged as a [PubDevFailure].
  Future<PubDevResult<String>> resolve({
    required String package,
    required String tool,
    String? supplied,
  }) async {
    if (supplied != null) return PubDevSuccess(supplied);

    _log(LoggingLevel.info, '$tool: resolving latest stable version for $package');
    final result = await _client.resolveLatestStable(package);
    return switch (result) {
      PubDevFailure(:final error) => PubDevFailure(error),
      PubDevSuccess(:final value) => _logResolved(tool, value),
    };
  }

  PubDevSuccess<String> _logResolved(String tool, String value) {
    _log(LoggingLevel.debug, '$tool: resolved version=$value');
    return PubDevSuccess(value);
  }
}
