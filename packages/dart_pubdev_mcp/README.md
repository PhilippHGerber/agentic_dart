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

Without live registry access, agents tend to:

- Recommend deprecated or unmaintained packages.
- Invent API method signatures that don't exist, or that changed versions ago.
- Miss breaking changes between the version they trained on and the version
  installed.
- Have no access at all to Dart/Flutter SDK framework source.

`dart-pubdev-explorer` backs every answer with a live call to pub.dev,
dartdoc, or the package tarball itself, so the agent's answer is grounded
instead of guessed.

For example, ask:

> "Compare `dio` and `http` for a Flutter app that needs file uploads —
> which has better platform support and is more actively maintained?"

The agent resolves this itself: `search_packages` to confirm both names
exist, `compare_packages` for the side-by-side score/platform/maintenance
matrix, then `get_symbol_documentation` if it needs to check a specific API
before recommending one.

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

All clients run the same stdio command with no arguments — only the config
shape differs.

**Claude Code (CLI)**

```bash
claude mcp add dart-pubdev-explorer -- dart-pubdev-explorer
```

**Cursor / VS Code / Antigravity / Windsurf (`.mcp.json`)**

```json
{
  "mcpServers": {
    "dart-pubdev-explorer": {
      "command": "dart-pubdev-explorer"
    }
  }
}
```

**Zed (`settings.json`)**

```json
{
  "context_servers": {
    "dart-pubdev-explorer": {
      "command": {
        "path": "dart-pubdev-explorer"
      }
    }
  }
}
```

Pass any of the [CLI flags](#configuration) below as extra args if you need
non-default behavior (custom cache directory, verbose logging, etc.).

### 3. Try it

Once connected, ask your agent something that needs live package data
instead of a training-data guess:

- "Find actively maintained Flutter state-management packages with web and
  iOS support."
- "Compare `dio` and `http` for file upload support, popularity, and pub
  points."
- "Show the signature and doc comment for `http.Client.send`."
- "List the breaking changes in `go_router` between 12.0.0 and 14.0.0."
- "Show how `StreamController` handles cancellation in `dart:async`."

## Tools

All tools return JSON and resolve to the latest stable version when
`version` is omitted.

### Package discovery and evaluation

- **`search_packages`** — find packages by keyword, filtered by SDK,
  platform, and sort order. Your starting point for "what should I use for X."
- **`get_package`** — full metadata for one package: score, SDK constraints,
  dependencies.
- **`compare_packages`** — score/platform/maintenance side by side for 2–5
  candidates, so an agent can justify a recommendation instead of asserting it.
- **`list_package_versions`** — every published version, bucketed into
  stable/prerelease/retracted.
- **`get_security_advisories`** — known security advisories for a package,
  evaluated against a specific version so the agent knows whether that
  version is actually affected, not just whether the package has ever had one.

### API and source inspection

- **`browse_api_symbols`** / **`find_symbols`** — search a package's public
  API by substring or fuzzy keyword, so the agent finds the real symbol
  before it writes code against it.
- **`get_symbol_documentation`** — the actual signature and doc comment for a
  symbol, instead of a remembered (and possibly outdated) one.
- **`get_throw_statements`** — every `throw` in a class or method, so the
  agent can write correct `try`/`catch` handling instead of guessing at
  exception types.
- **`get_source_slice`** — exact source, by line range or by symbol name,
  resolved through the analyzer AST — no manual tarball download required.
- **`list_package_source_files`** — browse a package's file tree to find
  examples or implementation files.
- **`grep_package_source`** — search across a package's whole source tree for
  a literal string or regex pattern, so an agent can find every call site of
  a symbol without enumerating and reading files one by one.

### Version diffs and upgrades

- **`get_changelog`** — structured changelog entries with a `breaking` flag,
  so an agent can tell you what actually changed instead of paraphrasing
  prose.
- **`get_api_diff`** — symbols added or removed between two versions, for
  upgrade-safety checks before bumping a dependency.

### SDK internals

- **`list_sdk_source_files`** / **`get_sdk_source_slice`** /
  **`get_sdk_throw_statements`** / **`grep_sdk_source`** — the same
  source-reading, throw-site, and search tools, but for the Dart SDK
  (`dart:core`, `dart:async`, …) and Flutter framework (`package:flutter`,
  …), which live outside pub.dev and are otherwise invisible to an agent.
  `grep_sdk_source` scans `.dart` files only by default, since an SDK or
  framework tarball is far noisier with non-Dart content than a pub.dev
  package.

Errors from any tool carry a machine-readable `code` and a `suggestion`
field describing the next step (e.g. `AMBIGUOUS_SYMBOL` includes candidate
qualified names to retry with).

## Resources

In addition to tools, the server exposes read-only MCP resources — raw
README/changelog/pubspec/example content, plus a couple of reference docs.
Read `pub://meta/resources` for the full manifest.

| URI | Content |
|---|---|
| `pub://meta/resources` | Manifest of every resource URI, MIME type, and description. |
| `pub://meta/scoring` | Plain-text explainer of pub.dev's 160-point scoring rubric. |
| `pub://meta/sdk-versions` | Current stable Dart and Flutter SDK versions as JSON. |
| `pub://package/{name}@{version}/readme` | Full README (Markdown). |
| `pub://package/{name}@{version}/changelog` | Full raw changelog text (Markdown). |
| `pub://package/{name}@{version}/example` | Working example code from the package's Example tab (Markdown). |
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
| `--no-update-check` | `dart_pubdev_mcp_UPDATE_CHECK` | on | Disable the startup Update Check against pub.dev for this server's own version. |

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
