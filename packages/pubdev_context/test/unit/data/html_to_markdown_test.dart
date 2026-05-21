/// Unit tests for [HtmlToMarkdown].
library;

import 'package:pubdev_context/src/data/html_to_markdown.dart';
import 'package:test/test.dart';

void main() {
  // ─── Tag-to-Markdown mapping ────────────────────────────────────────────────

  group('headings', () {
    test('h1 becomes # heading', () {
      expect(HtmlToMarkdown.convert('<h1>Title</h1>'), equals('# Title'));
    });

    test('h2 becomes ## heading', () {
      expect(HtmlToMarkdown.convert('<h2>Section</h2>'), equals('## Section'));
    });

    test('h3 becomes ### heading', () {
      expect(HtmlToMarkdown.convert('<h3>Sub</h3>'), equals('### Sub'));
    });
  });

  group('code blocks', () {
    test('pre becomes fenced code block', () {
      final result = HtmlToMarkdown.convert('<pre>abstract class Foo</pre>');
      expect(result, contains('```'));
      expect(result, contains('abstract class Foo'));
    });

    test('pre with inner code tag is treated as a unit', () {
      final result = HtmlToMarkdown.convert('<pre><code>abstract class Foo</code></pre>');
      expect(result, contains('```'));
      expect(result, contains('abstract class Foo'));
      expect(result, isNot(contains('``abstract'))); // no leaked backtick
    });

    test('inline code becomes backtick', () {
      expect(HtmlToMarkdown.convert('<code>Client</code>'), equals('`Client`'));
    });
  });

  group('definition lists', () {
    test('dt becomes list item', () {
      final result = HtmlToMarkdown.convert(
        '<dl><dt><code>close()</code></dt><dd>Closes the client.</dd></dl>',
      );
      expect(result, contains('- `close()`'));
      expect(result, contains('Closes the client.'));
    });
  });

  group('unordered lists', () {
    test('li becomes - bullet', () {
      final result = HtmlToMarkdown.convert('<ul><li>first</li><li>second</li></ul>');
      expect(result, contains('- first'));
      expect(result, contains('- second'));
    });
  });

  // ─── Noise stripping ────────────────────────────────────────────────────────

  group('inline emphasis', () {
    test('strong becomes **bold**', () {
      expect(HtmlToMarkdown.convert('<strong>bold</strong>'), equals('**bold**'));
    });

    test('b becomes **bold**', () {
      expect(HtmlToMarkdown.convert('<b>bold</b>'), equals('**bold**'));
    });

    test('em becomes *italic*', () {
      expect(HtmlToMarkdown.convert('<em>italic</em>'), equals('*italic*'));
    });

    test('i becomes *italic*', () {
      expect(HtmlToMarkdown.convert('<i>italic</i>'), equals('*italic*'));
    });

    test('del becomes ~~strikethrough~~', () {
      expect(HtmlToMarkdown.convert('<del>strike</del>'), equals('~~strike~~'));
    });

    test('s becomes ~~strikethrough~~', () {
      expect(HtmlToMarkdown.convert('<s>strike</s>'), equals('~~strike~~'));
    });

    test('nested em and strong produce ***bold italic***', () {
      expect(
        HtmlToMarkdown.convert('<em><strong>bold italic</strong></em>'),
        equals('***bold italic***'),
      );
    });

    test('wbr inside generic type is removed without a space', () {
      final result = HtmlToMarkdown.convert('Map&lt;<wbr>String&gt;');
      expect(result, equals('Map<String>'));
    });
  });

  group('headings h4-h6', () {
    test('h4 becomes #### heading', () {
      expect(HtmlToMarkdown.convert('<h4>Sub</h4>'), equals('#### Sub'));
    });

    test('h5 becomes ##### heading', () {
      expect(HtmlToMarkdown.convert('<h5>Sub</h5>'), equals('##### Sub'));
    });

    test('h6 becomes ###### heading', () {
      expect(HtmlToMarkdown.convert('<h6>Sub</h6>'), equals('###### Sub'));
    });
  });

  group('noise stripping', () {
    test('nav block is stripped entirely', () {
      final result = HtmlToMarkdown.convert('<nav><a>breadcrumb</a></nav><h1>Title</h1>');
      expect(result, isNot(contains('breadcrumb')));
      expect(result, contains('# Title'));
    });

    test('footer block is stripped entirely', () {
      final result = HtmlToMarkdown.convert('<h1>Title</h1><footer>v1.2.3</footer>');
      expect(result, isNot(contains('v1.2.3')));
      expect(result, contains('# Title'));
    });

    test('script block is stripped entirely', () {
      final result = HtmlToMarkdown.convert('<script>alert(1)</script><h1>Title</h1>');
      expect(result, isNot(contains('alert')));
    });

    test('style block is stripped entirely', () {
      final result = HtmlToMarkdown.convert('<style>.foo{color:red}</style><h1>Title</h1>');
      expect(result, isNot(contains('color')));
    });
  });

  // ─── HTML entities ──────────────────────────────────────────────────────────

  group('HTML entities', () {
    test('decodes &lt; and &gt;', () {
      expect(HtmlToMarkdown.convert('Map&lt;String, String&gt;'), equals('Map<String, String>'));
    });

    test('decodes &amp;', () {
      expect(HtmlToMarkdown.convert('foo &amp; bar'), equals('foo & bar'));
    });

    test('decodes &quot;', () {
      expect(HtmlToMarkdown.convert('say &quot;hello&quot;'), equals('say "hello"'));
    });

    test('decodes &#39;', () {
      expect(HtmlToMarkdown.convert('it&#39;s'), equals("it's"));
    });

    test('decodes &nbsp;', () {
      final result = HtmlToMarkdown.convert('foo&nbsp;bar');
      expect(result, equals('foo bar'));
    });
  });

  // ─── Section isolation ──────────────────────────────────────────────────────

  group('isolateTag', () {
    test('extracts content between the given tags', () {
      const html = '<nav>noise</nav><main><h1>Title</h1></main><footer>noise</footer>';
      final result = HtmlToMarkdown.convert(html, isolateTag: 'main');
      expect(result, contains('# Title'));
      expect(result, isNot(contains('noise')));
    });

    test('falls back to full HTML when tag is absent', () {
      final result = HtmlToMarkdown.convert('<h1>Title</h1>', isolateTag: 'main');
      expect(result, contains('# Title'));
    });
  });

  group('isolateClass', () {
    test('extracts content after the element with the given CSS class', () {
      const html = '<div class="desc markdown"><p>README content</p></div>';
      final result = HtmlToMarkdown.convert(html, isolateClass: 'desc markdown');
      expect(result, contains('README content'));
    });

    test('returns empty string when CSS class is absent', () {
      final result = HtmlToMarkdown.convert('<p>some content</p>', isolateClass: 'desc markdown');
      expect(result, isEmpty);
    });
  });

  // ─── Truncation ─────────────────────────────────────────────────────────────

  group('maxChars', () {
    test('truncates result and appends ellipsis when over limit', () {
      final html = '<p>${'a' * 200}</p>';
      final result = HtmlToMarkdown.convert(html, maxChars: 50);
      expect(result.length, equals(50));
      expect(result, endsWith('...'));
    });

    test('does not truncate when result is within limit', () {
      final result = HtmlToMarkdown.convert('<p>short</p>', maxChars: 100);
      expect(result, equals('short'));
    });
  });

  // ─── Whitespace normalisation ───────────────────────────────────────────────

  group('whitespace', () {
    test('collapses multiple spaces and tabs to a single space', () {
      final result = HtmlToMarkdown.convert('foo   \t   bar');
      expect(result, equals('foo bar'));
    });

    test('collapses three or more consecutive newlines to two', () {
      final result = HtmlToMarkdown.convert('a\n\n\n\nb');
      expect(result, equals('a\n\nb'));
    });

    test('strips remaining HTML tags', () {
      final result = HtmlToMarkdown.convert('<div class="x"><span>text</span></div>');
      expect(result, equals('text'));
      expect(result, isNot(contains('<')));
    });
  });
}
