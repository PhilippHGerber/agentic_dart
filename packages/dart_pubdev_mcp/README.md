# dart-pubdev-explorer

[![Pub Version](https://img.shields.io/pub/v/dart_pubdev_mcp.svg)](https://pub.dev/packages/dart_pubdev_mcp)
[![Pub Points](https://img.shields.io/pub/points/dart_pubdev_mcp.svg)](https://pub.dev/packages/dart_pubdev_mcp/score)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

*Ships as the `dart_pubdev_mcp` package on pub.dev; the server and CLI
identify themselves as `dart-pubdev-explorer`.*

A [Model Context Protocol](https://modelcontextprotocol.io) server that gives
AI coding agents structured, version-aware access to the pub.dev Dart and
Flutter package registry. Instead of scraping HTML, guessing package names,
or repeating stale advice from training data, an agent can search, compare,
and read packages — down to an exact source line — the way a careful
maintainer would.

## Why it exists

Agents without this server tend to guess package names, hallucinate APIs, or
paste in stale advice from training data. `dart-pubdev-explorer` backs every
answer with a live call to pub.dev, dartdoc, or the package tarball itself,
so an agent's answer is grounded instead of guessed.

## Features

- **Find the right package.** `search_packages` ranks by relevance, likes,
  pub points, or recency, filtered by SDK and platform.
- **Read the real docs.** Full READMEs, examples, changelogs, and
  `pubspec.yaml`, fetched at the exact version being targeted.
- **Browse the API like a human would.** Search a package's public symbols
  by name or keyword, then read full signatures, doc comments, and every
  `throw` site.
- **Read exact source.** Pull a file by line range or by symbol name —
  resolved through the analyzer AST — without downloading and unpacking a
  tarball by hand.
- **Compare candidates side by side.** Score, platform support, and
  maintenance signals for 2–5 packages in one call.
- **Plan upgrades with confidence.** Structured changelog entries flagged
  `breaking`, plus a symbol-level diff between any two versions.

## Quick start

### 1. Install

Requires the Dart SDK (`>=3.9.0`).

```bash
dart install dart_pubdev_mcp
```

This installs the `dart-pubdev-explorer` executable onto your `PATH`. Verify
with:

```bash
dart-pubdev-explorer --version
```

To upgrade later, re-run `dart install dart_pubdev_mcp` (add `--overwrite` if
another package has already claimed the `dart-pubdev-explorer` executable
name).

### 2. Configure your MCP client

Add a stdio server entry pointing at the installed executable. For example,
in Claude Code / Claude Desktop's `.mcp.json`:

```json
{
  "mcpServers": {
    "dart-pubdev-explorer": {
      "command": "dart-pubdev-explorer"
    }
  }
}
```

Any MCP client that speaks stdio works the same way — Cursor, Windsurf, Zed,
and others follow the same shape, a bare command with no arguments required.
Pass any of the [CLI flags](#configuration) below in `args` if you need
non-default behavior.

### 3. Try it

Once connected, ask your agent something that needs live package data
instead of training-data guesses, for example:

> "Compare `dio` and `http` for a Flutter app that needs file uploads —
> which has better platform support and is more actively maintained?"

The agent resolves this itself: `search_packages` to confirm both names
exist, `compare_packages` for the side-by-side score/platform/maintenance
matrix, then `get_symbol_documentation` if it needs to check a specific API
before recommending one.

## Tools

All tools return JSON. Every tool that accepts a package `version` omits it
to resolve the latest stable release, and the response then carries a
`resolvedVersion` field naming what was actually used.

| Tool | Purpose | Key parameters |
|---|---|---|
| `search_packages` | Find packages by keyword; the usual starting point. | `query` (required); `limit` (1–20, default 5); `page`; `sdk` (`dart`\|`flutter`); `platform` (`android`\|`ios`\|`web`\|`linux`\|`macos`\|`windows`); `sort` (`relevance`\|`likes`\|`pub_points`\|`updated`) |
| `get_package` | Full metadata for one package — score, SDK constraints, dependency count. | `name` (required); `version` (omit for latest) |
| `compare_packages` | Side-by-side score/platform/maintenance matrix for 2–5 candidates. | `names` (required, 2–5 entries) |
| `list_package_versions` | All published versions, bucketed into stable/prerelease/retracted with publish dates. | `name` (required) |
| `get_changelog` | Structured changelog entries with a `breaking` flag per entry. | `name` (required); `from_version` (skip already-known entries); `version_limit` (default 5) |
| `get_api_diff` | Symbols added/removed between two versions (presence-based, not signature diffs). | `package`, `fromVersion`, `toVersion` (all required) |
| `browse_api_symbols` | Search a package's dartdoc symbol index by name or keyword when the exact symbol name is unknown. | `package`, `query` (required); `type` (class/method/enum/etc.); `limit` (1–25, default 10); `version` |
| `find_symbols` | Same symbol index as `browse_api_symbols`, substring + fuzzy matched, capped at 20 results. | `package`, `query` (required); `version` |
| `get_symbol_documentation` | Full signature and doc comment for a known symbol (short name or qualified, e.g. `Client.send`). | `package`, `symbol` (required); `version` |
| `get_throw_statements` | Every `throw` in a class or method, with surrounding control-flow context. | `package` (required); `class`; `method` (at least one of `class`/`method` required); `version` |
| `get_source_slice` | Read source from one file — by line range, or by symbol name via the analyzer AST. | `package`, `file` (required); `version`; `lineStart`/`lineEnd`; `symbolName`; `maxLines` (collapse large symbols) |
| `list_package_source_files` | Browse a package's file tree, filtered by directory prefix and/or extension. | `name` (required); `version`; `directory`; `fileExtension` |

Errors from any tool carry a machine-readable `code` and a `suggestion`
field describing the next step (e.g. `AMBIGUOUS_SYMBOL` includes candidate
qualified names to retry with).

### Typical flows

- **Discovery:** `search_packages` → `get_package` → the `readme` resource
  for full setup docs.
- **API exploration:** `get_symbol_documentation` directly if the symbol name
  is known, otherwise `browse_api_symbols` first → `get_throw_statements` →
  `get_source_slice` if more implementation detail is needed.
- **Upgrade analysis:** `get_changelog` with `from_version` set → check
  `breaking` flags → `get_api_diff` for the precise symbol-level delta.
- **Choosing between packages:** `search_packages` → `compare_packages` on
  the top candidates.

## Resources

In addition to tools, the server exposes read-only MCP resources. Read
`pub://meta/resources` first to get the full manifest as JSON.

| URI | Content |
|---|---|
| `pub://meta/resources` | Manifest of every resource URI, MIME type, and description. |
| `pub://meta/instructions` | The same server instructions sent during the MCP handshake — re-read it if a workflow feels off. |
| `pub://meta/scoring` | Plain-text explainer of pub.dev's 160-point scoring rubric. |
| `pub://meta/sdk-versions` | Current stable Dart and Flutter SDK versions as JSON. |
| `pub://package/{name}@{version}/readme` | Full README (Markdown). |
| `pub://package/{name}@{version}/example` | Working example code from the package's Example tab (Markdown). |
| `pub://package/{name}@{version}/changelog` | Full raw changelog text (Markdown) — prefer the `get_changelog` tool for structured entries. |
| `pub://package/{name}@{version}/api` | Raw dartdoc symbol index (JSON) — prefer `browse_api_symbols`/`find_symbols` for filtered lookup. |
| `pub://package/{name}@{version}/pubspec` | Verbatim `pubspec.yaml` from the version's tarball. |

Package resource URIs require an explicit `@{version}` segment; use
`@latest` to resolve the latest stable release.

## Configuration

All settings are optional; CLI flags take precedence over environment
variables, which take precedence over defaults.

| Flag | Environment variable | Default | Purpose |
|---|---|---|---|
| `--log-level <level>` | `dart_pubdev_mcp_LOG_LEVEL` | `warning` | Minimum log severity: `debug`\|`info`\|`warning`\|`error`. |
| `--cache-dir <path>` | `dart_pubdev_mcp_CACHE_DIR` | `$XDG_CACHE_HOME/dart_pubdev_mcp` or `~/.cache/dart_pubdev_mcp` | Directory for the on-disk tarball cache. |
| `--max-cache-size <size>` | `dart_pubdev_mcp_MAX_CACHE_SIZE` | `500 MiB` | Total cap on the tarball disk cache. Accepts bytes or `KB`/`MB`/`GB`/`KiB`/`MiB`/`GiB` suffixes. |
| `--max-concurrent-requests <count>` | `dart_pubdev_mcp_MAX_CONCURRENT_REQUESTS` | `5` | Cap on simultaneous in-flight pub.dev HTTP requests (1–64). |
| `--wire-trace` | `dart_pubdev_mcp_WIRE_TRACE` | off | Enable a human-readable diagnostic log of every outbound HTTP request/response. |
| `--wire-trace-dir <path>` | `dart_pubdev_mcp_WIRE_TRACE_DIR` | `<cache-dir>/wire-trace` | Directory for per-session Wire Trace files. |
| `--wire-trace-max-preview <bytes>` | `dart_pubdev_mcp_WIRE_TRACE_MAX_PREVIEW` | `2048` | Cap on each logged response body preview; `0` logs metadata only. |

Run `dart-pubdev-explorer --help` for the same reference from the CLI, or
`dart-pubdev-explorer --version` to print the installed version.

## How this compares

The official Dart MCP server (`dart mcp-server`) ships a general
`pub_dev_search` tool alongside its much broader Dart/Flutter tooling
surface — running apps, analysis, DTD, and more. `dart-pubdev-explorer` is a
focused, deeper tool for package research specifically: symbol-level API
browsing, exact source reads, multi-version diffing, and side-by-side
comparison, backed by an on-disk cache tuned for the repeated lookups a
single research session tends to make. The two are complementary — run both.

## Contributing

Source, issues, and the changelog live in the
[`agentic_dart`](https://github.com/PhilippHGerber/agentic_dart) monorepo,
under `packages/dart_pubdev_mcp`. Bug reports and pull requests are welcome
via the [issue tracker](https://github.com/PhilippHGerber/agentic_dart/issues).

## License

MIT License — see [LICENSE](LICENSE).
