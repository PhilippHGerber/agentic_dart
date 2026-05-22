/// Central HTML-to-Markdown converter for dartdoc and pub.dev pages.
///
/// All PubDevClient extraction methods delegate here. The tag-to-Markdown rules
/// are shared; callers vary only the optional section-isolation and truncation
/// parameters.
library;

import 'package:html/parser.dart' show parse;

/// Converts dartdoc-flavoured HTML to Markdown.
///
/// The single shared rule set covers all HTML patterns produced by dartdoc and
/// pub.dev: headings, code blocks, definition lists, lists, and paragraphs.
/// Only section isolation differs per call site:
///
/// - Symbol docs: `isolateTag: 'main'` to drop nav/footer noise.
/// - README pages: `isolateClass: 'desc markdown'` to target the content div.
/// - Changelog pages: no isolation (the whole page is the changelog).
final class HtmlToMarkdown {
  const HtmlToMarkdown._();

  /// Converts [html] to Markdown.
  ///
  /// - [isolateTag]: if set, extracts content inside the first matching tag
  ///   (e.g. `'main'`). Falls back to the full HTML when not found.
  /// - [isolateClass]: if set, extracts content starting after the first
  ///   element with this CSS class (e.g. `'desc markdown'`). Returns `''`
  ///   when not found, preserving the empty-on-miss behaviour for optional
  ///   README sections.
  /// - [maxChars]: if set, truncates the result to at most this many
  ///   characters, appending `'...'` when truncated.
  static String convert(
    String html, {
    String? isolateTag,
    String? isolateClass,
    int? maxChars,
  }) {
    var content = html;
    if (isolateTag != null) content = _isolateByTag(content, isolateTag);
    if (isolateClass != null) {
      content = _isolateByClass(content, isolateClass);
      if (content.isEmpty) return '';
    }
    final result = _toMarkdown(content);
    if (maxChars != null && result.length > maxChars) {
      return '${result.substring(0, maxChars - 3)}...';
    }
    return result;
  }

  /// Returns the `innerHtml` of the first element matching [tag].
  ///
  /// Returns [html] unchanged when no such element exists.
  static String _isolateByTag(String html, String tag) {
    final element = parse(html).querySelector(tag);
    if (element == null) return html;
    return element.innerHtml;
  }

  /// Returns the `innerHtml` of the first element whose class list contains
  /// every whitespace-separated token in [cssClass].
  ///
  /// Returns `''` when no matching element exists.
  static String _isolateByClass(String html, String cssClass) {
    final required = cssClass.split(' ').where((t) => t.isNotEmpty).toSet();
    if (required.isEmpty) return '';
    for (final element in parse(html).querySelectorAll('*')) {
      if (element.classes.containsAll(required)) return element.innerHtml;
    }
    return '';
  }

  static String _toMarkdown(String html) {
    return html
        // ── Strip noisy blocks entirely ─────────────────────────────────────
        .replaceAll(RegExp('<nav[^>]*>.*?</nav>', dotAll: true, caseSensitive: false), '')
        .replaceAll(RegExp('<script[^>]*>.*?</script>', dotAll: true, caseSensitive: false), '')
        .replaceAll(RegExp('<style[^>]*>.*?</style>', dotAll: true, caseSensitive: false), '')
        .replaceAll(RegExp('<header[^>]*>.*?</header>', dotAll: true, caseSensitive: false), '')
        .replaceAll(RegExp('<footer[^>]*>.*?</footer>', dotAll: true, caseSensitive: false), '')
        // ── Headings ────────────────────────────────────────────────────────
        .replaceAll(RegExp('<h1[^>]*>'), '\n# ')
        .replaceAll('</h1>', '\n')
        .replaceAll(RegExp('<h2[^>]*>'), '\n## ')
        .replaceAll('</h2>', '\n')
        .replaceAll(RegExp('<h3[^>]*>'), '\n### ')
        .replaceAll('</h3>', '\n')
        .replaceAll(RegExp('<h4[^>]*>'), '\n#### ')
        .replaceAll('</h4>', '\n')
        .replaceAll(RegExp('<h5[^>]*>'), '\n##### ')
        .replaceAll('</h5>', '\n')
        .replaceAll(RegExp('<h6[^>]*>'), '\n###### ')
        .replaceAll('</h6>', '\n')
        // ── Code blocks — consume <pre><code>…</code></pre> as a unit ───────
        .replaceAll(RegExp('<pre[^>]*>(?:<code[^>]*>)?', dotAll: true), '\n```\n')
        .replaceAll(RegExp('(?:</code>)?</pre>'), '\n```\n')
        // ── Inline code ─────────────────────────────────────────────────────
        .replaceAll(RegExp('<code[^>]*>'), '`')
        .replaceAll('</code>', '`')
        // ── Inline emphasis ──────────────────────────────────────────────────────────
        .replaceAll(RegExp(r'<strong[^>]*>|<b(?=[\s>])[^>]*>'), '**')
        .replaceAll(RegExp('</strong>|</b>'), '**')
        .replaceAll(RegExp(r'<em[^>]*>|<i(?=[\s>])[^>]*>'), '*')
        .replaceAll(RegExp('</em>|</i>'), '*')
        .replaceAll(RegExp(r'<del[^>]*>|<s(?=[\s>])[^>]*>'), '~~')
        .replaceAll(RegExp('</del>|</s>'), '~~')
        // ── Definition lists (dt = member signature, dd = description) ──────
        .replaceAll(RegExp('<dt[^>]*>'), '\n- ')
        .replaceAll('</dt>', '')
        .replaceAll(RegExp('<dd[^>]*>'), '\n  ')
        .replaceAll('</dd>', '')
        // ── Unordered / ordered lists ────────────────────────────────────────
        .replaceAll(RegExp('<li[^>]*>'), '\n- ')
        .replaceAll('</li>', '')
        .replaceAll(RegExp('<[uo]l[^>]*>'), '\n')
        .replaceAll(RegExp('</[uo]l>'), '\n')
        // ── Paragraphs and line breaks ───────────────────────────────────────
        .replaceAll(RegExp('<p[^>]*>'), '\n\n')
        .replaceAll('</p>', '\n')
        .replaceAll(RegExp('<br[^>]*/?>'), '\n')
        // ── Strip all remaining tags ─────────────────────────────────────────
        .replaceAll(RegExp('<[^>]+>'), '')
        // ── HTML entities ────────────────────────────────────────────────────
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll(RegExp('[&][a-zA-Z]+;|&#[0-9]+;'), ' ')
        // ── Whitespace normalisation ─────────────────────────────────────────
        .replaceAll(RegExp('[ \t]+'), ' ')
        .replaceAll(RegExp('\r\n|\r'), '\n')
        .replaceAll(RegExp('\n[ \t]+\n'), '\n\n')
        .replaceAll(RegExp('\n{3,}'), '\n\n')
        .trim();
  }
}
