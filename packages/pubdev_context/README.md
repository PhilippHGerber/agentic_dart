# pubdev_context

A [Model Context Protocol](https://modelcontextprotocol.io/) server that exposes
pub.dev as a structured intelligence layer for AI assistants.

Built on the official [`dart_mcp`](https://pub.dev/packages/dart_mcp) framework.

> **Status:** experimental — tracking `dart_mcp ^0.5.1`

## Installation

```bash
dart pub global activate pubdev_context
```

## MCP client configuration

**Claude Desktop / Claude Code:**
```json
{
  "mcpServers": {
    "pubdev_context": { "command": "pubdev_context" }
  }
}
```

**Cursor / VS Code (with options):**
```json
{
  "mcpServers": {
    "pubdev_context": {
      "command": "pubdev_context",
      "env": {
        "pubdev_context_LOG_LEVEL": "debug"
      }
    }
  }
}
```

## Tools

| Tool                        | Description                                                                    |
| --------------------------- | ------------------------------------------------------------------------------ |
| `search_packages`           | Search pub.dev by keyword, SDK, platform, and sort order                       |
| `get_package`               | Full metadata for one package — scores, constraints, deps, README              |
| `get_changelog`             | Recent version history with computed `breaking` flags                          |
| `compare_packages`          | Side-by-side comparison matrix for 2–5 packages                                |
| `search_api_symbols`        | Search the dartdoc symbol index of a package by name or description            |
| `get_symbol_documentation`  | Full dartdoc page for a specific API symbol as plain text                      |
| `list_package_source_files` | File paths in a package tarball with optional directory and extension filters  |
| `get_package_source_file`   | Raw content of a single source file from the pub.dev tarball                   |

## Resources

| URI                               | Description                                              |
| --------------------------------- | -------------------------------------------------------- |
| `pub://meta/resources`            | Resource manifest — lists all available URIs (start here)|
| `pub://meta/scoring`              | pub.dev 160-point scoring system reference               |
| `pub://meta/sdk-versions`         | Current stable Dart and Flutter SDK versions as JSON     |
| `pub://package/{name}/readme`     | Full package README as `text/markdown`                   |
| `pub://package/{name}/example`    | Package example code as `text/markdown`                  |
| `pub://package/{name}/api`        | dartdoc symbol index as `application/json`               |
| `pub://package/{name}/changelog`  | Full changelog as `text/markdown`                        |

## Prompts

| Prompt                    | Description                                                                           |
| ------------------------- | ------------------------------------------------------------------------------------- |
| `add-and-setup-package`   | Guides through reading a README, writing boilerplate, and native setup steps          |
| `analyze-upgrade-impact`  | Retrieves changelog entries, identifies breaking changes, and rewrites affected code  |
| `evaluate-alternatives`   | Searches packages, compares top results, and produces a recommendation matrix         |

## Configuration

| Flag          | Env var                    | Default   | Description                   |
| ------------- | -------------------------- | --------- | ----------------------------- |
| `--log-level` | `pubdev_context_LOG_LEVEL` | `warning` | `error\|warning\|info\|debug` |
| `--cache-dir` | `pubdev_context_CACHE_DIR` | none      | Enable file-based cache       |
| `--version`   | —                          | —         | Print version and exit        |
| `--help`      | —                          | —         | Print usage and exit          |

## MCP Inspector (interactive browser UI)

```
npx @modelcontextprotocol/inspector pubdev_context
```

Opens a browser UI where you can call tools, inspect schemas, and see raw JSON-RPC responses.

## dart_mcp compatibility

| pubdev_context | dart_mcp |
| -------------- | -------- |
| `0.3.x`        | `^0.5.1` |
| `0.2.x`        | `^0.5.1` |
| `0.1.x`        | `^0.5.1` |

## License

MIT
