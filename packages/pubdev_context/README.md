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

| Tool              | Description                                    |
| ----------------- | ---------------------------------------------- |
| `search_packages` | Search pub.dev by keyword, SDK, and sort order |

## Configuration

| Flag          | Env var                 | Default   | Description                   |
| ------------- | ----------------------- | --------- | ----------------------------- |
| `--log-level` | `pubdev_context_LOG_LEVEL` | `warning` | `error\|warning\|info\|debug` |
| `--cache-dir` | `pubdev_context_CACHE_DIR` | none      | Enable file-based cache       |
| `--version`   | —                       | —         | Print version and exit        |
| `--help`      | —                       | —         | Print usage and exit          |

## Roadmap

### Tools

| Tool                | Description                                               |
| ------------------- | --------------------------------------------------------- |
| `get_package`       | Full metadata for one package in a single call            |
| `get_changelog`     | Recent version history with computed `breaking` flags     |
| `compare_packages`  | Side-by-side comparison matrix for 2–5 packages           |
| `find_alternatives` | Topic-matched and description-based alternative discovery |

### Resources

| URI                           | Description                                    |
| ----------------------------- | ---------------------------------------------- |
| `pub://meta/scoring`          | pub.dev 160-point scoring system reference     |
| `pub://meta/sdk-versions`     | Current stable Dart and Flutter SDK versions   |
| `pub://package/{name}/readme` | Full package README                            |
| `pub://package/{name}/api`    | dartdoc symbol index — all public API elements |

### Prompts

| Prompt                    | Parameters                              | Description                      |
| ------------------------- | --------------------------------------- | -------------------------------- |
| `evaluate_package`        | `name`, `use_case`                      | Guided single-package evaluation |
| `select_package_for_task` | `task_description`, `sdk?`, `platform?` | Guided package selection         |

## dart_mcp compatibility

| pubdev_context | dart_mcp |
| ----------- | -------- |
| `0.1.x`     | `^0.5.1` |

## License

MIT
