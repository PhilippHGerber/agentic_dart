# Agentic Dart

Dart and Flutter packages for AI tooling.

## Status

The product ships as the `dart_pubdev_mcp` package /
`dart-pubdev-explorer` MCP server identity, a Model Context Protocol server
that gives AI coding agents structured, version-aware access to the pub.dev
Dart/Flutter package registry (search, compare, symbol-level API browsing,
source reads, upgrade diffs). See
[`packages/dart_pubdev_mcp/README.md`](packages/dart_pubdev_mcp/README.md)
for the full pitch, client setup, and tool reference.

## Current workspace

- `packages/dart_pubdev_mcp/` the implementation.

## Working in this repository

This repository uses [Dart workspaces](https://dart.dev/tools/pub/workspaces).
A single `dart pub get` at the root resolves dependencies for all packages.

**Requirements:** Dart SDK `>=3.9.0`.

```bash
dart pub get
dart analyze
dart test packages/dart_pubdev_mcp
```

## Repository structure

```text
agentic_dart/
├── pubspec.yaml              ← Dart workspace root
└── packages/
        └── dart_pubdev_mcp/       ← the MCP server package
```



## License

MIT License, see individual package `LICENSE` files.