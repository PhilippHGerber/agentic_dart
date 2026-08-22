# dart-pubdev-explorer

[![Pub Version](https://img.shields.io/pub/v/dart_pubdev_mcp.svg)](https://pub.dev/packages/dart_pubdev_mcp)
[![Pub Points](https://img.shields.io/pub/points/dart_pubdev_mcp.svg)](https://pub.dev/packages/dart_pubdev_mcp/score)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![MCP Protocol](https://img.shields.io/badge/MCP-Model%20Context%20Protocol-8A2BE2.svg)](https://modelcontextprotocol.io)

> **Package name:** [`dart_pubdev_mcp`](https://pub.dev/packages/dart_pubdev_mcp) &nbsp;|&nbsp; **Executable / MCP identity:** `dart-pubdev-explorer`

A [Model Context Protocol (MCP)](https://modelcontextprotocol.io) server that gives AI coding assistants (Claude Code, Cursor, Windsurf, Zed, Roo Code, Cline, Antigravity) structured access to the [pub.dev](https://pub.dev) package registry, the Dart SDK, and the Flutter framework.

Instead of guessing package names, hallucinating APIs, or relying on outdated training data, your agent can search, compare, and inspect packages down to exact AST source slices and changelogs.

---

## Overview

- **Package discovery and evaluation**: Search by keywords, SDK, and platform. Compare 2 to 5 packages side by side on score, popularity, and maintenance.
- **AST-accurate API docs and source slices**: Fetch method signatures, doc comments, throw statements, and AST code slices without downloading tarballs manually.
- **Breaking changes and version diffs**: Parse changelogs and diff symbol additions or removals between dependency versions.
- **Dart and Flutter SDK internals**: Inspect internal framework code (`dart:core`, `dart:async`, `package:flutter`) and release notes that live outside pub.dev.
- **Security advisories**: Check version-specific vulnerabilities directly against the Open Source Vulnerability (OSV) database.

---

## Quick start

### 1. Install

Requires Dart SDK `>=3.9.0`.

```bash
dart install dart_pubdev_mcp
```

Verify that `dart-pubdev-explorer` is on your `PATH`:

```bash
dart-pubdev-explorer --version
```

*(To update later, run `dart install dart_pubdev_mcp` again. Add `--overwrite` if prompted.)*

---

### 2. Configure your MCP client

`dart-pubdev-explorer` communicates over standard I/O (`stdio`).

#### Claude Code (CLI)
```bash
claude mcp add dart-pubdev-explorer -- dart-pubdev-explorer
```

#### Cursor / VS Code / Antigravity / Windsurf (`.mcp.json` or MCP settings)
```json
{
  "mcpServers": {
    "dart-pubdev-explorer": {
      "command": "dart-pubdev-explorer"
    }
  }
}
```

#### Zed (`settings.json`)
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

#### Roo Code / Cline (`cline_mcp_settings.json`)
```json
{
  "mcpServers": {
    "dart-pubdev-explorer": {
      "command": "dart-pubdev-explorer",
      "args": []
    }
  }
}
```

---

### 3. Example prompts

Once configured, you can ask your AI assistant questions such as:

- *"Find actively maintained state-management packages for Flutter supporting Web and iOS."*
- *"Compare `dio` and `http` for a Flutter project with file uploads: check maintenance, pub points, and platform support."*
- *"Show the signature and doc comment for `http.Client.send`."*
- *"What breaking changes were introduced in `go_router` between version 12.0.0 and 14.0.0?"*
- *"How does `StreamController` handle cancellation in `dart:async`? Show the throw statements."*

---

## Why use dart-pubdev-explorer

| Challenge | Without dart-pubdev-explorer | With dart-pubdev-explorer |
|---|---|---|
| Package recommendations | Recommends deprecated or abandoned packages from training data. | Queries live pub.dev scores, popularity, maintenance status, and supported platforms. |
| API signatures | Hallucinates deprecated methods or incorrect argument types. | Inspects exact doc comments, type signatures, and AST slices from the targeted version. |
| Dependency upgrades | Guesses what broke between versions. | Performs automated API symbol diffs and extracts structured breaking-change changelogs. |
| Exception handling | Guesses what exceptions a method might throw. | Scans AST throw statements (`get_throw_statements`) for exact exception types. |
| SDK and framework source | Has no direct access to Dart SDK or Flutter framework code. | Navigates `dart:core`, `dart:async`, and `package:flutter` source directly. |

---

## Tools reference

All tools return structured JSON. When `version` is omitted, tools resolve to the latest stable release.

### Package discovery and evaluation
- `search_packages`: Search pub.dev with keyword queries, SDK filters, platform targets, and custom sorting.
- `get_package`: Complete package metadata, pub points score breakdown, verified publisher, and dependencies.
- `compare_packages`: Side-by-side comparison matrix (scores, platforms, maintenance, popularity) for 2 to 5 packages.
- `list_package_versions`: All published versions bucketed into `stable`, `prerelease`, and `retracted`.
- `get_security_advisories`: Version-specific vulnerability audits against the OSV registry.

### API and AST source inspection
- `browse_api_symbols` / `find_symbols`: Search and fuzzy-match public API classes, methods, and typedefs.
- `get_symbol_documentation`: Retrieve exact declaration signatures and dartdoc comments.
- `get_source_slice`: Extract precise source code by line range or symbol name via analyzer AST.
- `get_throw_statements`: Extract every `throw` within a method or class for accurate `try`/`catch` blocks.
- `list_package_source_files`: Browse package directory structure and example files.
- `grep_package_source`: Regex and literal string search across the full extracted package source tree.

### Version diffs and upgrades
- `get_changelog`: Structured release notes and breaking-change highlights across versions.
- `get_api_diff`: Detailed additions, removals, and breaking changes in public API symbols between two versions.

### Dart and Flutter SDK internals
- `get_sdk_release_notes`: Structured release notes and breaking changes for the Dart SDK and Flutter framework.
- `list_sdk_source_files` / `get_sdk_source_slice`: Browse and slice source code in `dart:*` and `package:flutter/*`.
- `get_sdk_throw_statements` / `grep_sdk_source`: Identify throw sites and search across SDK internals.

---

## MCP resources

Exposes read-only `pub://` resources for fast markdown and yaml inspection:

| Resource URI | Description |
|---|---|
| `pub://meta/resources` | Manifest of all available MCP resources and MIME types. |
| `pub://meta/scoring` | Detailed explainer of pub.dev's 160-point scoring rubric. |
| `pub://meta/sdk-versions` | Current stable Dart and Flutter SDK release versions (JSON). |
| `pub://package/{name}@{version}/readme` | Full README markdown for a specific package version (or `@latest`). |
| `pub://package/{name}@{version}/changelog` | Verbatim `CHANGELOG.md`. |
| `pub://package/{name}@{version}/example` | Working code from the package's Example tab. |
| `pub://package/{name}@{version}/pubspec` | Verbatim `pubspec.yaml` from the package archive. |

---

## Configuration

Settings can be passed via CLI flags or environment variables:

| Flag | Environment Variable | Default | Description |
|---|---|---|---|
| `--log-level <level>` | `dart_pubdev_mcp_LOG_LEVEL` | `warning` | Minimum logging level (`debug`, `info`, `warning`, `error`). |
| `--cache-dir <path>` | `dart_pubdev_mcp_CACHE_DIR` | `~/.cache/dart_pubdev_mcp` | Directory for disk-cached tarballs and AST index. |
| `--max-cache-size <size>` | `dart_pubdev_mcp_MAX_CACHE_SIZE` | `500 MiB` | Maximum disk cache capacity (e.g. `1 GB`, `500 MiB`). |
| `--max-concurrent-requests <n>` | `dart_pubdev_mcp_MAX_CONCURRENT_REQUESTS` | `5` | Cap on concurrent pub.dev HTTP requests (1 to 64). |
| `--wire-trace` | `dart_pubdev_mcp_WIRE_TRACE` | `false` | Enable detailed diagnostic log of outbound HTTP requests. |
| `--wire-trace-dir <path>` | `dart_pubdev_mcp_WIRE_TRACE_DIR` | `<cache-dir>/wire-trace` | Output directory for wire trace logs. |
| `--wire-trace-max-preview <bytes>` | `dart_pubdev_mcp_WIRE_TRACE_MAX_PREVIEW` | `2048` | Preview byte limit per HTTP response in wire logs. |
| `--no-update-check` | `dart_pubdev_mcp_UPDATE_CHECK` | `true` | Disable startup check for server version updates on pub.dev. |

---

## Complementary tooling

- **Official Dart MCP Server (`dart mcp-server`)**: Provides general runtime, debugging, DTD, and analysis tools for your local workspace.
- **`dart-pubdev-explorer` (`dart_pubdev_mcp`)**: Focuses on package registry lookup, symbol browsing, AST source slicing, SDK internals, and multi-version dependency diffing.

Running both servers together in your MCP client provides a complete Dart and Flutter development setup.

---

## Contributing and issues

- Repository: [`agentic_dart`](https://github.com/PhilippHGerber/agentic_dart)
- Issues and requests: [`agentic_dart/issues`](https://github.com/PhilippHGerber/agentic_dart/issues)

Pull requests and bug reports are welcome.

---

## License

MIT License. See [LICENSE](LICENSE).
