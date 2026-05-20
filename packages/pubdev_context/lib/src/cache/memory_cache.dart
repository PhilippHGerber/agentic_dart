/// In-memory TTL cache used by all tool and resource handlers.
///
/// Keys are strings derived from request URLs.
/// Each entry carries an expiry timestamp; expired entries are treated
/// as misses and evicted on next access.
///
/// TTL constants (named Durations) are defined here and used by handlers
/// to ensure consistent cache expiry across the codebase.
///
/// Pre-v1.0: gains a pluggable backend interface for file-based persistence
/// (see issue #14). The public interface defined here will not change.
library;

import 'dart:async';

/// A function returning the current point in time.
///
/// Inject a custom implementation in tests to control time without sleeping.
typedef Clock = DateTime Function();

/// TTL applied to search-result entries.
const Duration kSearchResultsTtl = Duration(minutes: 5);

/// TTL applied to package-metadata entries.
const Duration kPackageMetadataTtl = Duration(minutes: 15);

/// TTL applied to changelog entries.
const Duration kChangelogTtl = Duration(minutes: 15);

/// TTL applied to API-documentation index (`index.json`) entries.
const Duration kApiDocsTtl = Duration(hours: 1);

/// TTL applied to README entries.
const Duration kReadmeTtl = Duration(hours: 1);

/// TTL applied to meta-resource entries (scoring, SDK versions).
const Duration kMetaResourcesTtl = Duration(hours: 24);

/// A single cached entry pairing a [Future] value with its absolute [expiry].
final class _CacheEntry<T> {
  _CacheEntry(this.value, this.expiry);

  final Future<T> value;
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
  ResponseCache({Clock? clock}) : _clock = clock ?? DateTime.now;

  final Clock _clock;
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
    if (_clock().isAfter(entry.expiry)) {
      _entries.remove(key);
      _timers.remove(key)?.cancel();
      return null;
    }
    return entry.value;
  }

  /// Stores [value] under [key] with an absolute expiry of `now + ttl`.
  ///
  /// Call [set] with the [Future] before awaiting it so that concurrent callers
  /// retrieve the same in-flight call via [get], preventing duplicate HTTP requests.
  /// A [Timer] is scheduled to evict the entry after [ttl] even if [get] is
  /// never called again.
  void set(String key, Future<T> value, Duration ttl) {
    _timers.remove(key)?.cancel();
    _entries[key] = _CacheEntry(value, _clock().add(ttl));
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
