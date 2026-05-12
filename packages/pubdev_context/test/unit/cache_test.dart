/// Unit tests for [ResponseCache] and the TTL constants in memory_cache.dart.
library;

import 'package:pubdev_context/src/cache/memory_cache.dart';
import 'package:test/test.dart';

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
}
