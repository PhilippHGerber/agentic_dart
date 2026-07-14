/// A typed-identity caching facade over a private [ResponseCache].
///
/// [KeyedCache] concentrates the get→miss→fetch→set→skip-on-failure dance that
/// each handler used to re-implement over a raw [ResponseCache]. A caller holds
/// one instance per cached artifact and calls [KeyedCache.resolve] with a typed
/// identity; the cache-key format, TTL, single-flight, and skip-on-failure all
/// live behind the interface, so no caller can get any of them wrong.
///
/// The underlying [ResponseCache] is unchanged: TTL eviction, proactive timers,
/// Wire Trace hit logging, and the [KeyedCache.entries] snapshot all stay inside
/// it. [KeyedCache] adds identity→key derivation, a [PubDevResult]-aware
/// single-flight [KeyedCache.resolve], and the cache-only [KeyedCache.peek] /
/// [KeyedCache.entries] accessors that autocomplete needs.
library;

import 'dart:async';

import '../data/domain_error.dart';
import '../trace/wire_trace.dart';
import 'memory_cache.dart';

/// Derives the string cache key for an identity [id].
///
/// The identity [Id] is a typed value (typically a Dart record) supplied by the
/// caller; [KeyOf] maps it to the string key the underlying [ResponseCache]
/// stores under, so callers never build key strings themselves.
typedef KeyOf<Id> = String Function(Id id);

/// Fetches the value for [id], returning a cacheability-bearing [PubDevResult].
///
/// A [PubDevSuccess] is cached; a [PubDevFailure] passes through uncached.
typedef Fetch<Id, T> = Future<PubDevResult<T>> Function(Id id);

/// A caching facade addressed by a typed identity [Id] over a private
/// [ResponseCache] of values [T].
///
/// The fetch closure, key derivation, and TTL are fixed at construction, so
/// [resolve] is the entire call site. Concurrent [resolve] calls for the same
/// [Id] share a single in-flight fetch (single-flight); a [PubDevFailure] is
/// returned to every waiting caller and is never cached, so the next [resolve]
/// re-fetches.
final class KeyedCache<Id, T> {
  /// Creates a [KeyedCache].
  ///
  /// [keyOf] derives the storage key from an identity, [ttl] is applied to every
  /// cached success, and [fetch] produces the value on a miss. [clock] and
  /// [trace] are forwarded to the private [ResponseCache]; supply [clock] in
  /// tests to control time without sleeping.
  KeyedCache({
    required KeyOf<Id> keyOf,
    required Duration ttl,
    required Fetch<Id, T> fetch,
    Clock? clock,
    WireTrace? trace,
  }) : _keyOf = keyOf,
       _ttl = ttl,
       _fetch = fetch,
       _cache = ResponseCache<T>(clock: clock, trace: trace);

  final KeyOf<Id> _keyOf;
  final Duration _ttl;
  final Fetch<Id, T> _fetch;
  final ResponseCache<T> _cache;

  /// In-flight fetches keyed by derived cache key, so concurrent [resolve]
  /// calls for the same [Id] await one shared fetch instead of issuing
  /// duplicates. An entry is removed once its fetch settles (success or failure).
  final _inflight = <String, Future<PubDevResult<T>>>{};

  /// Resolves the value for [id], serving a cached success or fetching on a miss.
  ///
  /// On a hit, returns `PubDevSuccess(value)` without fetching. On a miss,
  /// registers a single in-flight fetch under the derived key: concurrent
  /// callers for the same [id] await that one fetch. A [PubDevSuccess] is cached
  /// for the configured TTL and returned; a [PubDevFailure] is returned
  /// uncached, so the next `resolve` re-fetches.
  Future<PubDevResult<T>> resolve(Id id) {
    final key = _keyOf(id);
    final cached = _cache.get(key);
    if (cached != null) {
      return cached.then<PubDevResult<T>>(PubDevSuccess<T>.new);
    }
    final existing = _inflight[key];
    if (existing != null) return existing;
    final future = _fetchAndCache(id, key);
    _inflight[key] = future;
    return future;
  }

  /// Runs the fetch for [id], caching a success under [key] and passing a
  /// failure through uncached. Clears the in-flight entry once settled.
  Future<PubDevResult<T>> _fetchAndCache(Id id, String key) async {
    try {
      final result = await _fetch(id);
      switch (result) {
        case PubDevSuccess(:final value):
          _cache.set(key, Future<T>.value(value), _ttl);
        case PubDevFailure():
          // Never cache a failure. Nothing is stored on a miss, so this is a
          // no-op today; it holds the invariant if a future path ever resolves
          // while a stale entry is present.
          _cache.invalidate(key);
      }
      return result;
    } finally {
      // Drop the settled in-flight future; its value has already been returned.
      final _ = _inflight.remove(key);
    }
  }

  /// Returns the cached value for [id] without fetching, or `null` on a miss.
  ///
  /// Cache-only: never triggers the fetch closure. Used by autocomplete paths
  /// that must issue no pub.dev call.
  Future<T>? peek(Id id) => _cache.get(_keyOf(id));

  /// A snapshot of all live, non-expired cache entries keyed by derived key.
  ///
  /// Cache-only, consumed by autocomplete. Delegates to [ResponseCache.entries],
  /// so expired entries are excluded.
  Map<String, Future<T>> get entries => _cache.entries;

  /// Cancels the underlying cache's pending timers and drops all entries.
  void dispose() => _cache.dispose();
}
