# Shared regex-based HTML-to-Markdown converter, not a DOM parser

All four HTML extraction paths (symbol docs, changelog, full README, README excerpt) previously duplicated entity decoding and whitespace normalisation as private static methods on `PubDevClient`. These were consolidated into a single `HtmlToMarkdown` class (`lib/src/data/html_to_markdown.dart`) using a regex pipeline.

`package:html` (a full DOM parser) was considered but rejected: dartdoc and pub.dev emit well-structured, machine-generated HTML where the tag patterns are predictable. A DOM parser would add a dependency and diverge from the existing regex style without buying robustness against malformed HTML — pub.dev never produces malformed HTML. The regex approach keeps zero new dependencies and is consistent with the existing `_extractChangelogText` pattern that was already structure-preserving.

The caller-configurable `isolateTag` / `isolateClass` parameters replace the per-method section-finding logic that was duplicated across the old private methods.
