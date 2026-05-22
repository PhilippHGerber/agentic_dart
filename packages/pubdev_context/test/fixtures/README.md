# Test Fixtures

Recorded real pub.dev responses used by unit tests.
Committed to the repository — these serve as deterministic test data
and living documentation of expected response shapes.

**Refreshing fixtures:**
Manually fetch and replace when pub.dev changes its API or HTML structure.
For HTML fixtures, re-run the extraction command documented below.

## JSON fixtures (API responses)

- `search_result.json`       — GET /api/search response
- `package_info.json`        — GET /api/packages/{name} response
- `package_score.json`       — GET /api/packages/{name}/score response
- `package_metrics.json`     — GET /api/packages/{name}/metrics response
- `index_json.json`          — dartdoc /documentation/{name}/latest/index.json

## HTML fixtures (`html/`)

`html/readme_{package}.html` — the `<section class="...detail-tab-readme-content...">` element
extracted from `https://pub.dev/packages/{package}`. Used by `html_to_markdown_real_world_test.dart`
to validate `HtmlToMarkdown.convert` against diverse real-world README styles.

Packages: `http`, `provider`, `riverpod`, `dio`, `equatable`, `freezed`, `path`, `go_router`,
`mocktail`, `intl`.

**To refresh all HTML fixtures:**
```sh
for pkg in http provider riverpod dio equatable freezed path go_router mocktail intl; do
  curl -sL "https://pub.dev/packages/$pkg" | python3 -c "
import sys, re
html = sys.stdin.read()
m = re.search(r'<section class=\"tab-content detail-tab-readme-content[^>]+>.*?</section>', html, re.DOTALL)
if m: print(m.group(0))
" > test/fixtures/html/readme_${pkg}.html
done
```
