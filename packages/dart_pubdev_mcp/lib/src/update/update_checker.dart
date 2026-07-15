/// The Update Check (see `CONTEXT.md`'s glossary entry): a background,
/// cross-restart-rate-limited lookup of this server's own Latest Stable
/// Version on pub.dev, compared against the running executable's version.
///
/// [UpdateChecker] owns the whole Update Check lifecycle: deciding whether a
/// fresh pub.dev lookup is due (via the persisted rate-limit state held by an
/// injected [UpdateCheckStateStore]), resolving the pub.dev side via the
/// existing [PubDevClient] fetch path when it is due, persisting the result,
/// and comparing whichever Latest Stable Version applies — freshly fetched or
/// reused from disk — against the running version. Scheduling *within* a
/// session (running it once, fire-and-forget, after startup) and delivery
/// (attaching the result to a tool response) remain the server's concern, not
/// this module's.
library;

import '../data/domain_error.dart';
import '../data/pub_client.dart';
import 'update_check_state_store.dart';

/// The pub.dev Package Identifier this server publishes itself as (see
/// `CONTEXT.md`). Distinct from `kMcpServerIdentity`, which is the
/// hyphenated name presented to MCP clients.
const kSelfPackageName = 'dart_pubdev_mcp';

/// How long a persisted Update Check result is reused before a restart
/// triggers a fresh pub.dev lookup again. Fixed — not configurable, per
/// `CONTEXT.md`'s Update Check entry.
const Duration kUpdateCheckRateLimitWindow = Duration(hours: 24);

/// Resolves [kSelfPackageName]'s Latest Stable Version on pub.dev — rate-limited
/// across restarts via an injected [UpdateCheckStateStore] — and compares it
/// against the running server's own version.
///
/// Any failure during a fresh check — network error, malformed response,
/// timeout — is caught and discarded entirely: [checkForUpdate] never throws
/// and never logs anything. A failed check is indistinguishable from "already
/// current", and is not persisted, so the next restart tries again rather than
/// being locked into a failure for the rate-limit window.
final class UpdateChecker {
  /// Creates an [UpdateChecker].
  ///
  /// [client] is the pub.dev HTTP gateway — the same [PubDevClient] every tool
  /// call already uses, so this check adds no new HTTP client or dependency.
  /// [currentVersion] is the running server's own version, from the existing
  /// generated version pipeline. [stateStore] persists the check's outcome
  /// across restarts; [now] and [rateLimitWindow] are overridable for tests,
  /// production callers should omit both.
  const UpdateChecker({
    required PubDevClient client,
    required String currentVersion,
    required UpdateCheckStateStore stateStore,
    DateTime Function() now = DateTime.now,
    Duration rateLimitWindow = kUpdateCheckRateLimitWindow,
  }) : _client = client,
       _currentVersion = currentVersion,
       _stateStore = stateStore,
       _now = now,
       _rateLimitWindow = rateLimitWindow;

  final PubDevClient _client;
  final String _currentVersion;
  final UpdateCheckStateStore _stateStore;
  final DateTime Function() _now;
  final Duration _rateLimitWindow;

  /// Returns the Latest Stable Version for [kSelfPackageName] — freshly
  /// resolved from pub.dev, or reused from [_stateStore] when a persisted
  /// result is still within [_rateLimitWindow] — when it is newer than
  /// [_currentVersion]; returns `null` when the server is already current, or
  /// when a fresh check was due but failed for any reason.
  Future<String?> checkForUpdate() async {
    final persisted = await _stateStore.read();
    final nowTime = _now();
    final latest = (persisted != null && nowTime.difference(persisted.checkedAt) < _rateLimitWindow)
        ? persisted.latestVersion
        : await _resolveFresh(nowTime);

    if (latest == null) return null;
    return _isNewer(latest, _currentVersion) ? latest : null;
  }

  /// Resolves [kSelfPackageName]'s Latest Stable Version fresh from pub.dev
  /// and, on success, persists it alongside [checkedAt]. Returns `null` on any
  /// failure, without persisting anything.
  Future<String?> _resolveFresh(DateTime checkedAt) async {
    try {
      final result = await _client.resolveLatestStable(kSelfPackageName);
      if (result is! PubDevSuccess<String>) return null;
      final latest = result.value;
      await _stateStore.write(UpdateCheckState(checkedAt: checkedAt, latestVersion: latest));
      return latest;
    } on Object {
      return null;
    }
  }

  /// Whether [candidate] is a strictly newer dotted-numeric version than
  /// [base]. Compares each `.`-separated segment numerically, treating a
  /// missing trailing segment as `0`; a non-numeric segment falls back to
  /// string comparison for that segment only. Sufficient here because
  /// [PubDevClient.resolveLatestStable] already excludes pre-release suffixes
  /// and the generated [_currentVersion] is always a plain `x.y.z` string —
  /// full semver precedence rules are not needed.
  static bool _isNewer(String candidate, String base) {
    final candidateParts = candidate.split('.');
    final baseParts = base.split('.');
    final length = candidateParts.length > baseParts.length
        ? candidateParts.length
        : baseParts.length;
    for (var i = 0; i < length; i++) {
      final candidatePart = i < candidateParts.length ? candidateParts[i] : '0';
      final basePart = i < baseParts.length ? baseParts[i] : '0';
      final candidateNum = int.tryParse(candidatePart);
      final baseNum = int.tryParse(basePart);
      final comparison = (candidateNum != null && baseNum != null)
          ? candidateNum.compareTo(baseNum)
          : candidatePart.compareTo(basePart);
      if (comparison != 0) return comparison > 0;
    }
    return false;
  }
}
