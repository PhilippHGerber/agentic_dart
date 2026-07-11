/// Unit tests for [KeyedCache] — the typed-identity caching facade.
///
/// Tests assert external behavior: what [KeyedCache.resolve] returns and how
/// many times the injected fetch runs — never the internal key string. Time is
/// injected via a fake clock, following the shape of `test/unit/cache_test.dart`.
library;

import 'dart:async';

import 'package:pubdev_context/src/cache/keyed_cache.dart';
import 'package:pubdev_context/src/data/domain_error.dart';
import 'package:test/test.dart';

/// A typed identity for the tests — a `(name, version)` record.
typedef _Id = ({String name, String version});

const _ttl = Duration(minutes: 15);

/// Builds a [DomainError] for the failure-path tests.
DomainError _error([String code = DomainErrors.serviceUnavailable]) =>
    DomainError(code: code, message: 'boom', suggestion: 'retry later');

/// A mutable boolean box, so a fetch closure can read a toggle the test flips
/// after construction.
final class _Toggle {
  bool value = true;
}

void main() {
  late DateTime fakeNow;
  DateTime fakeClock() => fakeNow;

  /// Counts how often the wired fetch closure ran, so tests can assert
  /// hits/misses and single-flight without inspecting cache internals.
  late int fetchCount;

  setUp(() {
    fakeNow = DateTime(2026);
    fetchCount = 0;
  });

  /// A [KeyedCache] wired to [respond], keying on `name:version` and counting
  /// every fetch. [respond] receives the resolved id and returns the result.
  KeyedCache<_Id, String> makeCache(
    Future<PubDevResult<String>> Function(_Id id) respond,
  ) => KeyedCache<_Id, String>(
    keyOf: (id) => '${id.name}:${id.version}',
    ttl: _ttl,
    clock: fakeClock,
    fetch: (id) {
      fetchCount++;
      return respond(id);
    },
  );

  /// A cache whose fetch always succeeds, echoing `<name>@<version>`.
  KeyedCache<_Id, String> succeedingCache() => makeCache(
    (id) async => PubDevSuccess('${id.name}@${id.version}'),
  );

  /// A cache that fails while [fail] is `true` and succeeds otherwise, plus the
  /// mutable toggle. Flip `fail.value` to change the next fetch's outcome.
  ({KeyedCache<_Id, String> cache, _Toggle fail}) flakyCache() {
    final fail = _Toggle();
    final cache = makeCache(
      (id) async => fail.value
          ? PubDevFailure(_error())
          : PubDevSuccess('${id.name}@${id.version}'),
    );
    return (cache: cache, fail: fail);
  }

  /// A cache whose every fetch blocks on [gate] before returning [result],
  /// so concurrent resolves can be lined up before any fetch completes.
  KeyedCache<_Id, String> gatedCache(
    Completer<void> gate,
    PubDevResult<String> Function(_Id id) result,
  ) => makeCache((id) async {
    await gate.future;
    return result(id);
  });

  group('resolve — hit and miss', () {
    test('a miss runs the fetch once and caches the success value', () async {
      final cache = succeedingCache();

      final result = await cache.resolve((name: 'http', version: '1.0.0'));

      expect(result, isA<PubDevSuccess<String>>());
      expect((result as PubDevSuccess<String>).value, 'http@1.0.0');
      expect(fetchCount, 1);
    });

    test('a repeat resolve within TTL is a hit that does not run the fetch', () async {
      final cache = succeedingCache();
      const id = (name: 'http', version: '1.0.0');

      final first = await cache.resolve(id);
      final second = await cache.resolve(id);

      expect((first as PubDevSuccess<String>).value, 'http@1.0.0');
      expect((second as PubDevSuccess<String>).value, 'http@1.0.0');
      expect(fetchCount, 1, reason: 'second resolve served from cache');
    });

    test('distinct identities are cached independently', () async {
      final cache = succeedingCache();

      final a = await cache.resolve((name: 'http', version: '1.0.0'));
      final b = await cache.resolve((name: 'dio', version: '5.0.0'));

      expect((a as PubDevSuccess<String>).value, 'http@1.0.0');
      expect((b as PubDevSuccess<String>).value, 'dio@5.0.0');
      expect(fetchCount, 2);
    });
  });

  group('resolve — TTL expiry', () {
    test('an entry past its TTL re-runs the fetch', () async {
      final cache = succeedingCache();
      const id = (name: 'http', version: '1.0.0');

      await cache.resolve(id);
      fakeNow = fakeNow.add(_ttl + const Duration(microseconds: 1));
      await cache.resolve(id);

      expect(fetchCount, 2);
    });

    test('an entry at exactly its TTL is still a hit', () async {
      final cache = succeedingCache();
      const id = (name: 'http', version: '1.0.0');

      await cache.resolve(id);
      fakeNow = fakeNow.add(_ttl); // isAfter is strict: still valid at expiry.
      await cache.resolve(id);

      expect(fetchCount, 1);
    });
  });

  group('resolve — failures are not cached', () {
    test('a failure is returned to the caller and not cached', () async {
      final (:cache, :fail) = flakyCache();
      const id = (name: 'http', version: '1.0.0');

      final failure = await cache.resolve(id);
      expect(failure, isA<PubDevFailure<String>>());
      expect((failure as PubDevFailure<String>).error.code,
          DomainErrors.serviceUnavailable);

      // The next resolve re-fetches; nothing was cached from the failure.
      fail.value = false;
      final success = await cache.resolve(id);
      expect((success as PubDevSuccess<String>).value, 'http@1.0.0');
      expect(fetchCount, 2);
    });

    test('a failure does not leave a stale in-flight entry', () async {
      final (:cache, :fail) = flakyCache();
      const id = (name: 'http', version: '1.0.0');

      await cache.resolve(id); // fails
      fail.value = false;
      await cache.resolve(id); // must fetch again, not await a dead in-flight
      final third = await cache.resolve(id); // now a hit

      expect(fetchCount, 2, reason: 'third call served from cache');
      expect((third as PubDevSuccess<String>).value, 'http@1.0.0');
    });
  });

  group('resolve — single-flight', () {
    test('two concurrent resolves for the same id share one fetch', () async {
      final gate = Completer<void>();
      final cache = gatedCache(
        gate,
        (id) => PubDevSuccess('${id.name}@${id.version}'),
      );
      const id = (name: 'http', version: '1.0.0');

      final a = cache.resolve(id);
      final b = cache.resolve(id);
      gate.complete();
      final results = await Future.wait([a, b]);

      expect(fetchCount, 1, reason: 'concurrent callers collapse to one fetch');
      expect((results[0] as PubDevSuccess<String>).value, 'http@1.0.0');
      expect((results[1] as PubDevSuccess<String>).value, 'http@1.0.0');
    });

    test('concurrent resolves for the same failing id both get the failure', () async {
      final gate = Completer<void>();
      final cache = gatedCache(gate, (id) => PubDevFailure(_error()));
      const id = (name: 'http', version: '1.0.0');

      final a = cache.resolve(id);
      final b = cache.resolve(id);
      gate.complete();
      final results = await Future.wait([a, b]);

      expect(fetchCount, 1);
      expect(results[0], isA<PubDevFailure<String>>());
      expect(results[1], isA<PubDevFailure<String>>());
    });

    test('concurrent resolves for distinct ids each fetch once', () async {
      final gate = Completer<void>();
      final cache = gatedCache(
        gate,
        (id) => PubDevSuccess('${id.name}@${id.version}'),
      );

      final a = cache.resolve((name: 'http', version: '1.0.0'));
      final b = cache.resolve((name: 'dio', version: '5.0.0'));
      gate.complete();
      await Future.wait([a, b]);

      expect(fetchCount, 2);
    });
  });

  group('peek', () {
    test('returns null on a miss without fetching', () async {
      final cache = succeedingCache();

      expect(cache.peek((name: 'http', version: '1.0.0')), isNull);
      expect(fetchCount, 0);
    });

    test('returns the cached value after a resolve, without fetching', () async {
      final cache = succeedingCache();
      const id = (name: 'http', version: '1.0.0');

      await cache.resolve(id);
      final peeked = cache.peek(id);

      expect(peeked, completion('http@1.0.0'));
      expect(fetchCount, 1, reason: 'peek issues no fetch');
    });

    test('returns null once the cached entry has expired', () async {
      final cache = succeedingCache();
      const id = (name: 'http', version: '1.0.0');

      await cache.resolve(id);
      fakeNow = fakeNow.add(_ttl + const Duration(microseconds: 1));

      expect(cache.peek(id), isNull);
    });
  });

  group('entries', () {
    test('is empty before any resolve', () {
      expect(succeedingCache().entries, isEmpty);
    });

    test('reflects live entries keyed by derived key', () async {
      final cache = succeedingCache();

      await cache.resolve((name: 'http', version: '1.0.0'));
      await cache.resolve((name: 'dio', version: '5.0.0'));

      expect(cache.entries.keys, containsAll(['http:1.0.0', 'dio:5.0.0']));
      expect(cache.entries['http:1.0.0'], completion('http@1.0.0'));
    });

    test('excludes expired entries', () async {
      final cache = succeedingCache();

      await cache.resolve((name: 'http', version: '1.0.0'));
      fakeNow = fakeNow.add(_ttl + const Duration(microseconds: 1));

      expect(cache.entries, isEmpty);
    });

    test('does not include a failed resolve', () async {
      final cache = makeCache((id) async => PubDevFailure(_error()));

      await cache.resolve((name: 'http', version: '1.0.0'));

      expect(cache.entries, isEmpty);
    });
  });
}
