/// Unit tests for [RetryPolicy].
library;

import 'package:pubdev_context/src/data/domain_error.dart';
import 'package:pubdev_context/src/data/pub_client.dart';
import 'package:test/test.dart';

Never _throwStatus(int code) => throw HttpStatusException(code);

RetryPolicy _fastRetry({int maxAttempts = 3}) => RetryPolicy(
  maxAttempts: maxAttempts,
  delay: (_) async {},
);

void main() {
  // ─── Success paths ─────────────────────────────────────────────────────────

  group('RetryPolicy — success', () {
    test('returns PubDevSuccess on the first attempt', () async {
      final result = await _fastRetry().execute(() async => 42);
      expect(result, isA<PubDevSuccess<int>>());
    });

    test('value equals the result returned by the operation', () async {
      final result = await _fastRetry().execute(() async => 'hello');
      expect((result as PubDevSuccess<String>).value, equals('hello'));
    });
  });

  // ─── Non-retryable errors ─────────────────────────────────────────────────

  group('RetryPolicy — non-retryable 4xx', () {
    test('does not retry on 404', () async {
      var attempts = 0;
      await _fastRetry().execute<int>(() async {
        attempts++;
        _throwStatus(404);
      });
      expect(attempts, equals(1));
    });

    test('error code is package_not_found on 404', () async {
      final result = await _fastRetry().execute<int>(() async => _throwStatus(404));
      expect(
        (result as PubDevFailure<int>).error.error,
        equals(DomainErrors.packageNotFound),
      );
    });

    test('does not retry on 400', () async {
      var attempts = 0;
      await _fastRetry().execute<int>(() async {
        attempts++;
        _throwStatus(400);
      });
      expect(attempts, equals(1));
    });

    test('does not retry on 403', () async {
      var attempts = 0;
      await _fastRetry().execute<int>(() async {
        attempts++;
        _throwStatus(403);
      });
      expect(attempts, equals(1));
    });

    test('returns PubDevFailure on 404', () async {
      final result = await _fastRetry().execute<int>(() async => _throwStatus(404));
      expect(result, isA<PubDevFailure<int>>());
    });
  });

  // ─── Retryable errors ─────────────────────────────────────────────────────

  group('RetryPolicy — retry on 5xx', () {
    test('retries up to maxAttempts on 500', () async {
      var attempts = 0;
      await _fastRetry().execute<int>(() async {
        attempts++;
        _throwStatus(500);
      });
      expect(attempts, equals(3));
    });

    test('retries on 502', () async {
      var attempts = 0;
      await _fastRetry().execute<int>(() async {
        attempts++;
        _throwStatus(502);
      });
      expect(attempts, equals(3));
    });

    test('retries on 503', () async {
      var attempts = 0;
      await _fastRetry().execute<int>(() async {
        attempts++;
        _throwStatus(503);
      });
      expect(attempts, equals(3));
    });

    test('retries on 504', () async {
      var attempts = 0;
      await _fastRetry().execute<int>(() async {
        attempts++;
        _throwStatus(504);
      });
      expect(attempts, equals(3));
    });

    test('returns service_unavailable after exhausting 5xx retries', () async {
      final result = await _fastRetry().execute<int>(() async => _throwStatus(500));
      expect(
        (result as PubDevFailure<int>).error.error,
        equals(DomainErrors.serviceUnavailable),
      );
    });

    test('succeeds on second attempt after an initial 500', () async {
      var attempts = 0;
      final result = await _fastRetry().execute<int>(() async {
        attempts++;
        if (attempts == 1) _throwStatus(500);
        return 99;
      });
      expect((result as PubDevSuccess<int>).value, equals(99));
      expect(attempts, equals(2));
    });
  });

  group('RetryPolicy — retry on 429', () {
    test('retries on 429', () async {
      var attempts = 0;
      await _fastRetry().execute<int>(() async {
        attempts++;
        _throwStatus(429);
      });
      expect(attempts, equals(3));
    });

    test('returns rate_limited when all failures are 429', () async {
      final result = await _fastRetry().execute<int>(() async => _throwStatus(429));
      expect(
        (result as PubDevFailure<int>).error.error,
        equals(DomainErrors.rateLimited),
      );
    });
  });

  // ─── Exhaustion domain error mapping ──────────────────────────────────────

  group('RetryPolicy — exhaustion error mapping', () {
    test('mixed 429 then 500 failures map to service_unavailable', () async {
      var count = 0;
      final result = await _fastRetry().execute<int>(() async {
        count++;
        _throwStatus(count == 1 ? 429 : 500);
      });
      expect(
        (result as PubDevFailure<int>).error.error,
        equals(DomainErrors.serviceUnavailable),
      );
    });

    test('all 429 failures produce rate_limited', () async {
      final result = await _fastRetry().execute<int>(() async => _throwStatus(429));
      expect(
        (result as PubDevFailure<int>).error.error,
        equals(DomainErrors.rateLimited),
      );
    });

    test('all 500 failures produce service_unavailable', () async {
      final result = await _fastRetry().execute<int>(() async => _throwStatus(500));
      expect(
        (result as PubDevFailure<int>).error.error,
        equals(DomainErrors.serviceUnavailable),
      );
    });
  });

  // ─── Delay sequencing ─────────────────────────────────────────────────────

  group('RetryPolicy — delay sequencing', () {
    test('applies exponential delays of 500 ms then 1 000 ms', () async {
      final delays = <Duration>[];
      final policy = RetryPolicy(
        delay: (d) async => delays.add(d),
      );
      await policy.execute<int>(() async => _throwStatus(500));
      expect(
        delays,
        equals(const [
          Duration(milliseconds: 500),
          Duration(milliseconds: 1000),
        ]),
      );
    });

    test('no delay is introduced before the first attempt', () async {
      final delays = <Duration>[];
      final policy = RetryPolicy(delay: (d) async => delays.add(d));
      await policy.execute(() async => 1);
      expect(delays, isEmpty);
    });
  });

  // ─── maxAttempts ──────────────────────────────────────────────────────────

  group('RetryPolicy — maxAttempts', () {
    test('respects maxAttempts of 1', () async {
      var attempts = 0;
      await RetryPolicy(maxAttempts: 1, delay: (_) async {}).execute<int>(
        () async {
          attempts++;
          _throwStatus(500);
        },
      );
      expect(attempts, equals(1));
    });

    test('respects maxAttempts of 2', () async {
      var attempts = 0;
      await RetryPolicy(maxAttempts: 2, delay: (_) async {}).execute<int>(
        () async {
          attempts++;
          _throwStatus(500);
        },
      );
      expect(attempts, equals(2));
    });
  });
}
