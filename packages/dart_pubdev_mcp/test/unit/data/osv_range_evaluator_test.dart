/// Unit tests for [osvRangesAffectVersion].
library;

import 'package:dart_pubdev_mcp/src/data/models.dart';
import 'package:dart_pubdev_mcp/src/data/osv_range_evaluator.dart';
import 'package:test/test.dart';

OsvRange _range(List<OsvEvent> events) => OsvRange(events: events);

void main() {
  group('introduced/fixed pair (http-shaped)', () {
    final ranges = [
      _range([const OsvEvent(introduced: '0'), const OsvEvent(fixed: '0.13.3')]),
    ];

    test('a version before fixed is affected', () {
      expect(osvRangesAffectVersion(ranges, '0.12.0'), isTrue);
    });

    test('the fixed version itself is not affected', () {
      expect(osvRangesAffectVersion(ranges, '0.13.3'), isFalse);
    });

    test('a version after fixed is not affected', () {
      expect(osvRangesAffectVersion(ranges, '1.0.0'), isFalse);
    });

    test('the earliest possible version is affected', () {
      expect(osvRangesAffectVersion(ranges, '0.0.1'), isTrue);
    });
  });

  group('open-ended range (introduced with no fixed)', () {
    final ranges = [
      _range([const OsvEvent(introduced: '1.0.0')]),
    ];

    test('a version at introduced is affected', () {
      expect(osvRangesAffectVersion(ranges, '1.0.0'), isTrue);
    });

    test('a much later version is still affected — no upper bound', () {
      expect(osvRangesAffectVersion(ranges, '99.0.0'), isTrue);
    });

    test('a version before introduced is not affected', () {
      expect(osvRangesAffectVersion(ranges, '0.9.0'), isFalse);
    });
  });

  group('lastAffected boundary (inclusive)', () {
    final ranges = [
      _range([const OsvEvent(introduced: '0'), const OsvEvent(lastAffected: '1.5.0')]),
    ];

    test('the lastAffected version itself is still affected', () {
      expect(osvRangesAffectVersion(ranges, '1.5.0'), isTrue);
    });

    test('a version after lastAffected is not affected', () {
      expect(osvRangesAffectVersion(ranges, '1.5.1'), isFalse);
    });
  });

  group('limit boundary (exclusive, like fixed)', () {
    final ranges = [
      _range([const OsvEvent(introduced: '0'), const OsvEvent(limit: '2.0.0')]),
    ];

    test('a version before limit is affected', () {
      expect(osvRangesAffectVersion(ranges, '1.9.9'), isTrue);
    });

    test('the limit version itself is not affected', () {
      expect(osvRangesAffectVersion(ranges, '2.0.0'), isFalse);
    });
  });

  group('multiple affected entries (ranges OR together)', () {
    final ranges = [
      _range([const OsvEvent(introduced: '0'), const OsvEvent(fixed: '1.0.0')]),
      _range([const OsvEvent(introduced: '2.0.0'), const OsvEvent(fixed: '3.0.0')]),
    ];

    test('a version in the first range is affected', () {
      expect(osvRangesAffectVersion(ranges, '0.5.0'), isTrue);
    });

    test('a version in the second range is affected', () {
      expect(osvRangesAffectVersion(ranges, '2.5.0'), isTrue);
    });

    test('a version between the two ranges is not affected', () {
      expect(osvRangesAffectVersion(ranges, '1.5.0'), isFalse);
    });

    test('a version after both ranges is not affected', () {
      expect(osvRangesAffectVersion(ranges, '4.0.0'), isFalse);
    });
  });

  group('reintroduced vulnerability (introduced, fixed, introduced again)', () {
    final ranges = [
      _range([
        const OsvEvent(introduced: '0'),
        const OsvEvent(fixed: '1.0.0'),
        const OsvEvent(introduced: '1.5.0'),
      ]),
    ];

    test('a version before the first fix is affected', () {
      expect(osvRangesAffectVersion(ranges, '0.5.0'), isTrue);
    });

    test('a version between the fix and the reintroduction is not affected', () {
      expect(osvRangesAffectVersion(ranges, '1.2.0'), isFalse);
    });

    test('a version at the reintroduction is affected again', () {
      expect(osvRangesAffectVersion(ranges, '2.0.0'), isTrue);
    });
  });

  group('pre-release and build-metadata versions', () {
    final ranges = [
      _range([const OsvEvent(introduced: '0'), const OsvEvent(fixed: '0.13.3')]),
    ];

    test('a pre-release before fixed is affected', () {
      expect(osvRangesAffectVersion(ranges, '0.13.0-nullsafety.0'), isTrue);
    });

    test('a build-metadata version before fixed is affected', () {
      expect(osvRangesAffectVersion(ranges, '0.11.0+1'), isTrue);
    });
  });

  group('no ranges', () {
    test('an advisory with no affected ranges never matches', () {
      expect(osvRangesAffectVersion(const [], '1.0.0'), isFalse);
    });
  });

  group('unparseable input', () {
    final ranges = [
      _range([const OsvEvent(introduced: '0')]),
    ];

    test('an unparseable resolved version never matches', () {
      expect(osvRangesAffectVersion(ranges, 'not-a-version'), isFalse);
    });

    test('an unparseable event boundary is skipped rather than crashing', () {
      final malformed = [
        _range([const OsvEvent(introduced: '0'), const OsvEvent(fixed: 'not-a-version')]),
      ];
      expect(osvRangesAffectVersion(malformed, '5.0.0'), isTrue);
    });
  });
}
