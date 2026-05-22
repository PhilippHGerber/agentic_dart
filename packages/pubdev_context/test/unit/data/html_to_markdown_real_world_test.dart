/// Real-world fixture tests for [HtmlToMarkdown] using saved pub.dev HTML pages.
///
/// Fixtures are the `<section class="...detail-tab-readme-content...">` element
/// extracted from pub.dev package listing pages. They exercise diverse README
/// styles: long/short, code-heavy, multi-language, emoji, badge-rich.
library;

import 'dart:io';

import 'package:pubdev_context/src/data/html_to_markdown.dart';
import 'package:test/test.dart';

// The single class token that identifies the README section on pub.dev
// listing pages. Matched against element.classes using containsAll.
const _readmeClass = 'detail-tab-readme-content';

String _fixture(String package) =>
    File('test/fixtures/html/readme_$package.html').readAsStringSync();

Matcher _noHtmlTag(String tag) => isNot(contains(tag));

void _expectCleanMarkdown(String output, {required String pkg}) {
  expect(output, isNotEmpty, reason: '$pkg: output is empty');
  expect(output.length, greaterThan(200), reason: '$pkg: output is suspiciously short');

  // Block-level tags that _toMarkdown must have converted or stripped.
  for (final tag in const [
    '<div',
    '</div>',
    '<span',
    '</span>',
    '<p>',
    '</p>',
    '<ul>',
    '</ul>',
    '<ol>',
    '</ol>',
    '<li>',
    '</li>',
    '<nav>',
    '</nav>',
    '<footer',
    '<header',
    '<script',
    '<style',
  ]) {
    expect(output, _noHtmlTag(tag), reason: '$pkg: raw tag "$tag" survived conversion');
  }

  // HTML entities that _toMarkdown must have decoded.
  for (final entity in const [
    '&amp;',
    '&lt;',
    '&gt;',
    '&nbsp;',
    '&quot;',
    '&apos;',
  ]) {
    expect(output, isNot(contains(entity)), reason: '$pkg: entity "$entity" was not decoded');
  }
}

void main() {
  group('real-world pub.dev README fixtures', () {
    test('http — composable networking library', () {
      final output = HtmlToMarkdown.convert(
        _fixture('http'),
        isolateClass: _readmeClass,
      );
      _expectCleanMarkdown(output, pkg: 'http');
      expect(output, contains('composable'));
    });

    test('provider — InheritedWidget wrapper', () {
      final output = HtmlToMarkdown.convert(
        _fixture('provider'),
        isolateClass: _readmeClass,
      );
      _expectCleanMarkdown(output, pkg: 'provider');
      expect(output, contains('InheritedWidget'));
    });

    test('riverpod — reactive caching framework', () {
      final output = HtmlToMarkdown.convert(
        _fixture('riverpod'),
        isolateClass: _readmeClass,
      );
      _expectCleanMarkdown(output, pkg: 'riverpod');
      expect(output, contains('Riverpod'));
    });

    test('dio — HTTP networking with interceptors', () {
      final output = HtmlToMarkdown.convert(
        _fixture('dio'),
        isolateClass: _readmeClass,
      );
      _expectCleanMarkdown(output, pkg: 'dio');
      expect(output, contains('Dio'));
    });

    test('equatable — value equality via == override', () {
      final output = HtmlToMarkdown.convert(
        _fixture('equatable'),
        isolateClass: _readmeClass,
      );
      _expectCleanMarkdown(output, pkg: 'equatable');
      expect(output, contains('Equality'));
    });

    test('freezed — code generation for data classes', () {
      final output = HtmlToMarkdown.convert(
        _fixture('freezed'),
        isolateClass: _readmeClass,
      );
      _expectCleanMarkdown(output, pkg: 'freezed');
      expect(output, contains('Freezed'));
    });

    test('path — cross-platform path manipulation', () {
      final output = HtmlToMarkdown.convert(
        _fixture('path'),
        isolateClass: _readmeClass,
      );
      _expectCleanMarkdown(output, pkg: 'path');
      expect(output, contains('cross-platform'));
    });

    test('go_router — declarative routing for Flutter', () {
      final output = HtmlToMarkdown.convert(
        _fixture('go_router'),
        isolateClass: _readmeClass,
      );
      _expectCleanMarkdown(output, pkg: 'go_router');
      expect(output, contains('declarative'));
    });

    test('mocktail — mock library for Dart', () {
      final output = HtmlToMarkdown.convert(
        _fixture('mocktail'),
        isolateClass: _readmeClass,
      );
      _expectCleanMarkdown(output, pkg: 'mocktail');
      expect(output, contains('Mock'));
    });

    test('intl — internationalization and localization', () {
      final output = HtmlToMarkdown.convert(
        _fixture('intl'),
        isolateClass: _readmeClass,
      );
      _expectCleanMarkdown(output, pkg: 'intl');
      expect(output, contains('localization'));
    });
  });
}
