/// In-memory TTL cache used by all tool and resource handlers.
///
/// Keys are strings derived from request URLs.
/// Each entry carries an expiry timestamp; expired entries are treated
/// as misses and evicted on next access.
///
/// This is a mechanism-only module: it defines the cache implementation, not
/// cache policy. Most TTL constants live in `cache_registry.dart`, the single
/// home for `CacheRegistry`'s key formats, TTLs, and fetch wiring.
/// [kPackageMetadataTtl] is the one exception — it stays here because
/// `pub_client.dart`'s private Package Info Cache uses it directly, outside
/// `CacheRegistry`.
///
/// Pre-v1.0: gains a pluggable backend interface for file-based persistence
/// (see issue #14). The public interface defined here will not change.
library;

import 'dart:async';

import '../trace/wire_trace.dart';

/// A function returning the current point in time.
///
/// Inject a custom implementation in tests to control time without sleeping.
typedef Clock = DateTime Function();

/// TTL applied to package-metadata entries.
///
/// Shared by `CacheRegistry`'s `packageDetail` facade and `pub_client.dart`'s
/// private Package Info Cache — both derive from `GET /api/packages/{name}`.
const Duration kPackageMetadataTtl = Duration(minutes: 15);

/// A single cached entry pairing a [Future] value with its [createdAt] time and
/// absolute [expiry].
final class _CacheEntry<T> {
  _CacheEntry(this.value, this.createdAt, this.expiry);

  final Future<T> value;

  /// When the entry was stored — used to report a cache hit's age in the trace.
  final DateTime createdAt;

  final DateTime expiry;
}

/// A generic in-memory TTL cache used by all tool and resource handlers.
///
/// Keys are strings derived from request URLs. Each entry stores a [Future<T>]
/// so that concurrent requests for the same key share a single in-flight HTTP
/// call rather than issuing duplicate requests (cache-stampede prevention):
/// call [set] with the [Future] before awaiting it.
///
/// Expired entries are evicted both on the next access and proactively via a
/// [Timer] scheduled at the TTL deadline, preventing unbounded memory growth
/// in long-running sessions where entries are never re-queried.
final class ResponseCache<T> {
  /// Creates a [ResponseCache].
  ///
  /// Supply [clock] in tests to control time without sleeping;
  /// defaults to [DateTime.now].
  ///
  /// When an enabled [trace] is supplied, each [get] that resolves to a hit
  /// *while a traced request is on the stack* emits a `⚡ cache hit` line to the
  /// Wire Trace, correlated to that request via the ambient [Zone] id. Hits
  /// outside a traced request (for example autocomplete lookups, which run
  /// without a Correlation Id) emit nothing. When [trace] is null the cache is
  /// untraced and pays nothing.
  ResponseCache({Clock? clock, WireTrace? trace})
    : _clock = clock ?? DateTime.now,
      _trace = trace;

  final Clock _clock;
  final WireTrace? _trace;
  final _entries = <String, _CacheEntry<T>>{};
  final _timers = <String, Timer>{};

  /// Returns a snapshot of all non-expired cache entries, keyed by their cache key.
  ///
  /// Each value is the in-flight or completed [Future] originally passed to [set].
  /// This getter is synchronous — callers that need the resolved values must await
  /// each future individually. Expired entries are excluded from the returned map.
  Map<String, Future<T>> get entries {
    final now = _clock();
    return {
      for (final entry in _entries.entries)
        if (!now.isAfter(entry.value.expiry)) entry.key: entry.value.value,
    };
  }

  /// Returns the cached [Future] for [key], or `null` on a miss or after TTL expiry.
  ///
  /// An expired entry is removed before returning `null`.
  Future<T>? get(String key) {
    final entry = _entries[key];
    if (entry == null) return null;
    final now = _clock();
    if (now.isAfter(entry.expiry)) {
      _entries.remove(key);
      _timers.remove(key)?.cancel();
      return null;
    }
    _traceHit(key, now.difference(entry.createdAt));
    return entry.value;
  }

  /// Emits a `⚡ cache hit` line for [key] when tracing is enabled and a traced
  /// request (carrying a Correlation Id on the current [Zone]) is on the stack.
  ///
  /// Reading the id from the ambient Zone at call time is what keeps a cache hit
  /// attributed to the request that provoked it, and what excludes cache lookups
  /// made outside any traced request (such as autocomplete) from the trace.
  void _traceHit(String key, Duration age) {
    final trace = _trace;
    if (trace == null) return;
    final id = currentCorrelationId();
    if (id == null) return;
    trace.logCacheHit(id: id, key: key, age: age);
  }

  /// Stores [value] under [key] with an absolute expiry of `now + ttl`.
  ///
  /// Call [set] with the [Future] before awaiting it so that concurrent callers
  /// retrieve the same in-flight call via [get], preventing duplicate HTTP requests.
  /// A [Timer] is scheduled to evict the entry after [ttl] even if [get] is
  /// never called again.
  void set(String key, Future<T> value, Duration ttl) {
    _timers.remove(key)?.cancel();
    final now = _clock();
    _entries[key] = _CacheEntry(value, now, now.add(ttl));
    _timers[key] = Timer(ttl, () {
      _entries.remove(key);
      _timers.remove(key);
    });
  }

  /// Removes the entry for [key] and cancels its pending eviction timer.
  void invalidate(String key) {
    _entries.remove(key);
    _timers.remove(key)?.cancel();
  }

  /// Removes all entries and cancels all pending eviction timers.
  void clear() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _entries.clear();
    _timers.clear();
  }

  /// Cancels all pending timers and removes all entries.
  ///
  /// Call when the cache is no longer needed to prevent timer callbacks from
  /// firing after the owning object is discarded.
  void dispose() => clear();
}
