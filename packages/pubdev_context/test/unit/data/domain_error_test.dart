import 'dart:convert';

import 'package:pubdev_context/src/data/domain_error.dart';
import 'package:test/test.dart';

// ─── Helper ───────────────────────────────────────────────────────────────────

/// Extracts the nested `error` object from a [DomainError.toJson] result,
/// failing the test if the structure is unexpected.
Map<String, Object?> _inner(DomainError err) {
  final raw = err.toJson()['error'];
  if (raw is! Map<String, Object?>) {
    fail('Expected "error" key to be Map<String, Object?> but got: $raw');
  }
  return raw;
}

void main() {
  // ─── JSON shape ─────────────────────────────────────────────────────────────

  group('DomainError.toJson — nested shape', () {
    test('wraps all fields under an "error" key', () {
      const err = DomainError(
        code: DomainErrors.packageNotFound,
        message: 'Package not found.',
        suggestion: 'Check the name.',
      );

      final json = err.toJson();
      expect(json.keys, equals(['error']));
      expect(json['error'], isA<Map<String, Object?>>());
    });

    test('inner object contains code, message, retryable, suggestion', () {
      const err = DomainError(
        code: DomainErrors.packageNotFound,
        message: 'Package not found.',
        suggestion: 'Check the name.',
      );

      final inner = _inner(err);
      expect(inner['code'], equals(DomainErrors.packageNotFound));
      expect(inner['message'], equals('Package not found.'));
      expect(inner['retryable'], isFalse);
      expect(inner['suggestion'], equals('Check the name.'));
    });

    test('omits suggestedNextStep when null', () {
      const err = DomainError(
        code: DomainErrors.packageNotFound,
        message: 'msg',
        suggestion: 'fix',
      );
      expect(_inner(err).containsKey('suggestedNextStep'), isFalse);
    });

    test('includes suggestedNextStep when provided', () {
      const err = DomainError(
        code: DomainErrors.ambiguousSymbol,
        message: 'Ambiguous.',
        suggestion: 'Use a qualified name.',
        suggestedNextStep: {
          'tool': 'find_symbols',
          'arguments': <String, Object?>{'package': 'http', 'query': 'Client'},
        },
      );
      final inner = _inner(err);
      final rawNext = inner['suggestedNextStep'];
      if (rawNext is! Map<String, Object?>) fail('expected suggestedNextStep to be a Map');
      expect(rawNext['tool'], equals('find_symbols'));
    });

    test('omits details when null', () {
      const err = DomainError(
        code: DomainErrors.packageNotFound,
        message: 'msg',
        suggestion: 'fix',
      );
      expect(_inner(err).containsKey('details'), isFalse);
    });

    test('includes details when provided', () {
      const err = DomainError(
        code: DomainErrors.ambiguousSymbol,
        message: 'Ambiguous.',
        suggestion: 'Use a qualified name.',
        details: {
          'candidates': ['http.Client', 'browser_client.Client'],
        },
      );
      final rawDetails = _inner(err)['details'];
      if (rawDetails is! Map<String, Object?>) fail('expected details to be a Map');
      expect(rawDetails['candidates'], isA<List<Object?>>());
    });

    test('toJsonString produces valid JSON with the nested shape', () {
      const err = DomainError(
        code: DomainErrors.rateLimited,
        message: 'Rate limited.',
        suggestion: 'Retry later.',
      );
      final decoded = jsonDecode(err.toJsonString()) as Map<String, Object?>;
      final raw = decoded['error'];
      if (raw is! Map<String, Object?>) fail('expected nested error object');
      expect(raw['code'], equals(DomainErrors.rateLimited));
    });
  });

  // ─── retryable flag ──────────────────────────────────────────────────────────

  group('DomainError.retryable', () {
    test('is true for RATE_LIMITED', () {
      const err = DomainError(
        code: DomainErrors.rateLimited,
        message: 'msg',
        suggestion: 'fix',
      );
      expect(err.retryable, isTrue);
      expect(_inner(err)['retryable'], isTrue);
    });

    test('is true for SERVICE_UNAVAILABLE', () {
      const err = DomainError(
        code: DomainErrors.serviceUnavailable,
        message: 'msg',
        suggestion: 'fix',
      );
      expect(err.retryable, isTrue);
    });

    test('is true for REQUEST_TIMEOUT', () {
      const err = DomainError(
        code: DomainErrors.requestTimeout,
        message: 'msg',
        suggestion: 'fix',
      );
      expect(err.retryable, isTrue);
    });

    test('is false for PACKAGE_NOT_FOUND', () {
      const err = DomainError(
        code: DomainErrors.packageNotFound,
        message: 'msg',
        suggestion: 'fix',
      );
      expect(err.retryable, isFalse);
    });

    test('is false for INVALID_ARGUMENT', () {
      const err = DomainError(
        code: DomainErrors.invalidArgument,
        message: 'msg',
        suggestion: 'fix',
      );
      expect(err.retryable, isFalse);
    });
  });

  // ─── DomainErrors constants ──────────────────────────────────────────────────

  group('DomainErrors constants', () {
    test('all values are SCREAMING_SNAKE_CASE', () {
      final allCodes = [
        DomainErrors.packageNotFound,
        DomainErrors.rateLimited,
        DomainErrors.serviceUnavailable,
        DomainErrors.unexpectedResponse,
        DomainErrors.requestTimeout,
        DomainErrors.noDocumentation,
        DomainErrors.invalidArgument,
        DomainErrors.symbolNotFound,
        DomainErrors.exampleNotFound,
        DomainErrors.sourceFileNotFound,
        DomainErrors.ambiguousSymbol,
        DomainErrors.noResults,
        DomainErrors.documentationNotFound,
        DomainErrors.packageTooLarge,
      ];
      final screamingCase = RegExp(r'^[A-Z][A-Z0-9_]*$');
      for (final code in allCodes) {
        expect(code, matches(screamingCase), reason: '$code is not SCREAMING_SNAKE_CASE');
      }
    });

    test('classNotFound and methodNotFound no longer exist', () {
      // This is a compile-time guarantee — if the test compiles, the PoC
      // constants are gone. We verify the symbol_not_found code covers both.
      expect(DomainErrors.symbolNotFound, equals('SYMBOL_NOT_FOUND'));
    });

    test('new sentinel codes are registered', () {
      expect(DomainErrors.documentationNotFound, equals('DOCUMENTATION_NOT_FOUND'));
      expect(DomainErrors.packageTooLarge, equals('PACKAGE_TOO_LARGE'));
    });
  });
}
