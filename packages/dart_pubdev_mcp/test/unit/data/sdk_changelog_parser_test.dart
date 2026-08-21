/// Unit tests for [parseSdkChangelogText].
library;

import 'package:dart_pubdev_mcp/src/data/sdk_changelog_parser.dart';
import 'package:test/test.dart';

void main() {
  group('parseSdkChangelogText', () {
    test('parses basic Dart SDK changelog with sections and subsections', () {
      const markdown = '''
# Dart SDK Changelog

## 3.14.0 - 2025-01-15

### Libraries

#### dart:ffi
- Added NativeFinalizer.callback support for native callbacks.
- Fixed struct allocation leak.

### Tools

#### Formatter
- Don't crash on invalid pattern syntax.

## 3.13.0

### Language
- Added new language feature.

### Breaking changes
- Removed deprecated API `foo()`.
''';

      final entries = parseSdkChangelogText(markdown);
      expect(entries.length, equals(2));

      final first = entries[0];
      expect(first.version, equals('3.14.0'));
      expect(first.date, equals(DateTime.utc(2025, 1, 15)));
      expect(first.breaking, isFalse);
      expect(first.sections.keys, containsAll(['Libraries', 'Tools']));
      expect(first.sections['Libraries'], equals([
        'dart:ffi: Added NativeFinalizer.callback support for native callbacks.',
        'dart:ffi: Fixed struct allocation leak.',
      ]));
      expect(first.sections['Tools'], equals([
        "Formatter: Don't crash on invalid pattern syntax.",
      ]));
      expect(first.changes, equals([
        'dart:ffi: Added NativeFinalizer.callback support for native callbacks.',
        'dart:ffi: Fixed struct allocation leak.',
        "Formatter: Don't crash on invalid pattern syntax.",
      ]));

      final second = entries[1];
      expect(second.version, equals('3.13.0'));
      expect(second.date, isNull);
      expect(second.breaking, isTrue);
      expect(second.sections['Language'], equals(['Added new language feature.']));
      expect(second.sections['Breaking changes'], equals(['Removed deprecated API `foo()`.']));
      expect(second.changes, equals([
        'Added new language feature.',
        'Removed deprecated API `foo()`.',
      ]));
    });

    test('parses Flutter SDK changelog with hotfixes and parenthesized dates', () {
      const markdown = '''
## 3.24.1 (2024-08-06)

### Hotfixes
- Fixes #12345: engine crash on iOS when rendering text.

## 3.24.0

### Framework
- Updated scrollbar theme defaults.
''';

      final entries = parseSdkChangelogText(markdown);
      expect(entries.length, equals(2));

      expect(entries[0].version, equals('3.24.1'));
      expect(entries[0].date, equals(DateTime.utc(2024, 8, 6)));
      expect(entries[0].sections['Hotfixes'], equals([
        'Fixes #12345: engine crash on iOS when rendering text.',
      ]));

      expect(entries[1].version, equals('3.24.0'));
      expect(entries[1].sections['Framework'], equals([
        'Updated scrollbar theme defaults.',
      ]));
    });

    test('parses multi-line bullet items and preserves content', () {
      const markdown = '''
## 3.1.0

### Core libraries
- Added `Future.wait` error handling improvements
  with better stack traces on failure.
- Added `Stream.multi`.
''';

      final entries = parseSdkChangelogText(markdown);
      expect(entries.length, equals(1));
      expect(entries[0].changes, equals([
        'Added `Future.wait` error handling improvements with better stack traces on failure.',
        'Added `Stream.multi`.',
      ]));
    });

    test('detects breaking changes via section name or content', () {
      const markdown = '''
## 3.0.0

### Language
- **Breaking Change**: Sound null safety is now required.
''';

      final entries = parseSdkChangelogText(markdown);
      expect(entries.length, equals(1));
      expect(entries[0].breaking, isTrue);
    });

    test('returns empty list when no version headings are present', () {
      const markdown = 'Just some notes without headings.';
      expect(parseSdkChangelogText(markdown), isEmpty);
    });
  });
}
