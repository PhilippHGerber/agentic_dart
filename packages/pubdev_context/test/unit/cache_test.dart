/// Unit tests for [ResponseCache] and the TTL constants in memory_cache.dart.
library;

import 'dart:async';

import 'package:pubdev_context/src/cache/memory_cache.dart';
import 'package:pubdev_context/src/trace/wire_trace.dart';
import 'package:test/test.dart';

/// A [WireTraceSink] that records emitted lines in memory.
final class _RecordingSink implements WireTraceSink {
  final List<String> lines = <String>[];

  @override
  void writeLine(String line) => lines.add(line);

  @override
  void close() {}
}

void main() {
  late DateTime fakeNow;
  DateTime fakeClock() => fakeNow;

  group('TTL constants', () {
    test('kSearchResultsTtl is 5 minutes', () {
      expect(kSearchResultsTtl, equals(const Duration(minutes: 5)));
    });

    test('kPackageMetadataTtl is 15 minutes', () {
      expect(kPackageMetadataTtl, equals(const Duration(minutes: 15)));
    });

    test('kChangelogTtl is 15 minutes', () {
      expect(kChangelogTtl, equals(const Duration(minutes: 15)));
    });

    test('kApiDocsTtl is 60 minutes', () {
      expect(kApiDocsTtl, equals(const Duration(hours: 1)));
    });

    test('kReadmeTtl is 60 minutes', () {
      expect(kReadmeTtl, equals(const Duration(hours: 1)));
    });

    test('kMetaResourcesTtl is 24 hours', () {
      expect(kMetaResourcesTtl, equals(const Duration(hours: 24)));
    });
  });

  group('ResponseCache.get', () {
    late ResponseCache<String> cache;

    setUp(() {
      fakeNow = DateTime(2026);
      cache = ResponseCache(clock: fakeClock);
    });

    test('returns null for a missing key', () {
      expect(cache.get('missing'), isNull);
    });

    test('returns the stored future for an unexpired key', () {
      final future = Future.value('hello');
      cache.set('key', future, const Duration(minutes: 5));

      expect(cache.get('key'), same(future));
    });

    test('returns the same future instance on repeated hits', () {
      final future = Future.value('hello');
      cache.set('key', future, const Duration(minutes: 5));

      expect(cache.get('key'), same(cache.get('key')));
    });

    test('returns the entry at exactly the expiry moment', () {
      // isAfter is strict: at exactly expiry the entry is still valid.
      cache.set('key', Future.value('hello'), const Duration(minutes: 5));
      fakeNow = fakeNow.add(const Duration(minutes: 5));

      expect(cache.get('key'), isNotNull);
    });

    test('returns null one microsecond past TTL expiry', () {
      cache.set('key', Future.value('hello'), const Duration(minutes: 5));
      fakeNow = fakeNow.add(const Duration(minutes: 5, microseconds: 1));

      expect(cache.get('key'), isNull);
    });

    test('allows re-setting the same key after expiry evicts the stale entry', () {
      cache.set('key', Future.value('stale'), const Duration(minutes: 5));
      fakeNow = fakeNow.add(const Duration(minutes: 5, microseconds: 1));
      // get() evicts the expired entry; the null return is the assertion.
      expect(cache.get('key'), isNull);

      final fresh = Future.value('fresh');
      cache.set('key', fresh, const Duration(minutes: 5));
      expect(cache.get('key'), same(fresh));
    });
  });

  group('ResponseCache.set', () {
    late ResponseCache<String> cache;

    setUp(() {
      fakeNow = DateTime(2026);
      cache = ResponseCache(clock: fakeClock);
    });

    test('overwrites an existing entry with a new future', () {
      cache.set('key', Future.value('first'), const Duration(minutes: 5));
      final second = Future.value('second');
      cache.set('key', second, const Duration(minutes: 5));

      expect(cache.get('key'), same(second));
    });

    test('stores the future before it resolves for stampede prevention', () {
      final future = Future.value('value');
      cache.set('key', future, const Duration(minutes: 5));

      // Both callers get the exact same Future instance.
      expect(cache.get('key'), same(future));
      expect(cache.get('key'), same(future));
    });
  });

  group('ResponseCache.invalidate', () {
    late ResponseCache<String> cache;

    setUp(() {
      fakeNow = DateTime(2026);
      cache = ResponseCache(clock: fakeClock);
    });

    test('removes an existing entry', () {
      cache
        ..set('key', Future.value('hello'), const Duration(minutes: 5))
        ..invalidate('key');

      expect(cache.get('key'), isNull);
    });

    test('is a no-op for a missing key', () {
      expect(() => cache.invalidate('nonexistent'), returnsNormally);
    });

    test('does not affect other entries', () {
      final other = Future.value('other');
      cache
        ..set('key', Future.value('hello'), const Duration(minutes: 5))
        ..set('other', other, const Duration(minutes: 5))
        ..invalidate('key');

      expect(cache.get('other'), same(other));
    });
  });

  group('ResponseCache — proactive eviction', () {
    test('entry is absent after TTL fires without any get() call', () async {
      final cache = ResponseCache<String>();
      addTearDown(cache.dispose);
      cache.set('key', Future.value('v'), const Duration(milliseconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(cache.get('key'), isNull);
    });

    test('invalidate cancels timer so a re-added entry survives the original TTL window', () async {
      final cache = ResponseCache<String>();
      addTearDown(cache.dispose);
      cache
        ..set('key', Future.value('v1'), const Duration(milliseconds: 10))
        ..invalidate('key');
      final future = Future.value('v2');
      cache.set('key', future, const Duration(seconds: 60));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(cache.get('key'), same(future));
    });

    test('clear cancels pending timers', () async {
      final cache = ResponseCache<String>()
        ..set('a', Future.value('1'), const Duration(milliseconds: 10))
        ..set('b', Future.value('2'), const Duration(milliseconds: 10))
        ..clear();
      // Re-add entries with a long TTL; if old timers had not been cancelled they
      // would fire during the delay and remove the newly added entries.
      final fa = Future.value('a2');
      final fb = Future.value('b2');
      cache
        ..set('a', fa, const Duration(seconds: 60))
        ..set('b', fb, const Duration(seconds: 60));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(cache.get('a'), same(fa));
      expect(cache.get('b'), same(fb));
      cache.dispose();
    });
  });

  group('ResponseCache.clear', () {
    late ResponseCache<String> cache;

    setUp(() {
      fakeNow = DateTime(2026);
      cache = ResponseCache(clock: fakeClock);
    });

    test('removes all entries', () {
      cache
        ..set('a', Future.value('1'), const Duration(minutes: 5))
        ..set('b', Future.value('2'), const Duration(minutes: 5))
        ..clear();

      expect(cache.get('a'), isNull);
      expect(cache.get('b'), isNull);
    });

    test('is a no-op on an empty cache', () {
      expect(() => cache.clear(), returnsNormally);
    });

    test('allows new entries after clearing', () {
      cache
        ..set('key', Future.value('old'), const Duration(minutes: 5))
        ..clear();
      final fresh = Future.value('new');
      cache.set('key', fresh, const Duration(minutes: 5));

      expect(cache.get('key'), same(fresh));
    });
  });

  group('ResponseCache — cache-hit tracing', () {
    late _RecordingSink sink;
    late WireTrace trace;
    late ResponseCache<String> cache;

    setUp(() {
      fakeNow = DateTime(2026);
      sink = _RecordingSink();
      trace = WireTrace.withSink(
        sink,
        serverVersion: '0.0.0-test',
        maxPreviewBytes: 2048,
        concurrency: 5,
        cacheDir: '/tmp',
      );
      cache = ResponseCache(clock: fakeClock, trace: trace);
    });

    /// The `⚡ cache hit` lines emitted so far (header lines excluded).
    List<String> hitLines() =>
        sink.lines.where((l) => l.contains('⚡ cache hit')).toList();

    /// Reads [key] as if inside a traced request carrying Correlation Id [id].
    /// The looked-up future is intentionally discarded — the tests assert on the
    /// trace side effect, not the value.
    void getInTracedRequest(String id, String key) => runZoned(
      () {
        final _ = cache.get(key);
      },
      zoneValues: {wireTraceZoneIdKey: id},
    );

    test('a hit inside a traced request emits one cache-hit line with key and age', () {
      cache.set('versions:http', Future.value('v'), const Duration(minutes: 15));
      fakeNow = fakeNow.add(const Duration(seconds: 12));

      getInTracedRequest('#007', 'versions:http');

      expect(hitLines(), hasLength(1));
      expect(hitLines().single, contains('#007'));
      expect(hitLines().single, contains('cache hit  versions:http'));
      expect(hitLines().single, contains('age 12s'));
    });

    test('a hit outside any traced request (no Correlation Id) emits nothing', () {
      cache.set('versions:http', Future.value('v'), const Duration(minutes: 15));

      // No Zone id — models an autocomplete lookup, which must not be traced.
      final _ = cache.get('versions:http');

      expect(hitLines(), isEmpty);
    });

    test('a miss emits nothing even inside a traced request', () {
      getInTracedRequest('#001', 'absent');

      expect(hitLines(), isEmpty);
    });

    test('an expired entry is a miss and emits nothing', () {
      cache.set('versions:http', Future.value('v'), const Duration(minutes: 15));
      fakeNow = fakeNow.add(const Duration(minutes: 15, microseconds: 1));

      getInTracedRequest('#001', 'versions:http');

      expect(hitLines(), isEmpty);
    });

    test('an untraced cache (trace: null) never logs', () {
      final untraced = ResponseCache<String>(clock: fakeClock)
        ..set('k', Future.value('v'), const Duration(minutes: 5));

      // A hit inside a traced Zone still emits nothing: the cache holds no trace.
      runZoned(
        () {
          final _ = untraced.get('k');
        },
        zoneValues: {wireTraceZoneIdKey: '#001'},
      );

      expect(hitLines(), isEmpty);
    });
  });
}
