# Agentic Dart

Dart and Flutter packages for AI tooling.

---

## Packages

| Package                                | Description                                                                                                         | pub.dev                                                                                              |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| [`pubdev_context`](packages/pubdev_context/) | pub.dev intelligence MCP server — search, evaluate, compare, and inspect packages from any MCP-compatible AI client | [![pub package](https://img.shields.io/pub/v/pubdev_context.svg)](https://pub.dev/packages/pubdev_context) |


---

## Getting started

### Using a package

Each package is a standalone pub.dev tool or library.
See the individual package README for installation and configuration instructions.

```bash
# Example: install pubdev_context as a global CLI tool
dart pub global activate pubdev_context
```

### Working in this repository

This repository uses [Dart workspaces](https://dart.dev/tools/pub/workspaces).
A single `dart pub get` at the root resolves dependencies for all packages.

**Requirements:** Dart SDK `>=3.9.0` — [install here](https://dart.dev/get-dart).

```bash
# Clone and install all dependencies
git clone https://github.com/PhilippHGerber/agentic_dart.git
cd agentic_dart
dart pub get
```

**Common commands:**

```bash
# Analyse all packages
dart analyze

# Run tests for a specific package
dart test packages/pubdev_context

# Activate a package locally for end-to-end testing
dart pub global activate -s path packages/pubdev_context
```

---

## Repository structure

```
agentic_dart/
├── pubspec.yaml        ← Dart workspace root
└── packages/
    └── pubdev_context/        ← pub.dev intelligence MCP server
        ├── bin/        ← executable entry point
        ├── lib/        ← importable library
        ├── test/
        │   ├── unit/         ← mocked HTTP, runs in CI
        │   ├── integration/  ← live API calls, run manually
        │   └── fixtures/     ← recorded pub.dev responses
        ├── example/
        └── benchmark/
```

Each package under `packages/` is independently versioned and published.


---

## Contributing

Contributions are welcome. Before opening a pull request:

1. **Check existing issues** — the work may already be tracked.
2. **One package per PR** — keep changes scoped to a single `packages/` subtree.
3. **Tests required** — unit tests must pass; integration tests must be run manually before requesting review.
4. **No lint errors** — `dart analyze` must pass with zero issues.
5. **English only** — all code comments and doc comments are in English.

For significant changes, open an issue first to discuss the approach.

---

## dart_mcp compatibility

Each package documents its `dart_mcp` version compatibility in its own README.
`dart_mcp` is experimental and evolves quickly; compatibility is tracked
per package per minor release.

| Package             | dart_mcp |
| ------------------- | -------- |
| `pubdev_context 0.1.x` | `^0.5.1` |

---

## License

MIT License — see individual package `LICENSE` files.