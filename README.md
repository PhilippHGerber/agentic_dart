# Agentic Dart

Dart and Flutter packages for AI tooling.

## Status

The existing `pubdev_context` work in this repository is was created as a proof of concept.

Its historical documentation, ADRs, review notes, generated docs, and issue
history were moved to `archive/poc/pubdev_context/` so the real product can be
started on this code base without inheriting PoC decisions as active
constraints.

Archived PoC material is intentionally historical and outdated. It remains
available for reference, but it should not block new product decisions.

**Naming:** the V1 product will ship as the `dart_pubdev_mcp` package /
`dart-pubdev-explorer` MCP server identity, replacing `pubdev_context` (see
`packages/pubdev_context/docs/adr/0006-rename-to-dart-pubdev-mcp.md`). The
rename happens at V1 cutover — until then this repo still uses the
`pubdev_context` name throughout.

## Current workspace

- `archive/poc/pubdev_context/` contains the archived PoC narrative and
    decision trail.
- `packages/pubdev_context/` PoC implementation as base for new code
    (pre-cutover name — will become `dart_pubdev_mcp` per ADR 0006).

## Working in this repository

This repository uses [Dart workspaces](https://dart.dev/tools/pub/workspaces).
A single `dart pub get` at the root resolves dependencies for all packages.

**Requirements:** Dart SDK `>=3.9.0`.

```bash
dart pub get
dart analyze
dart test packages/pubdev_context
```

## Repository structure

```text
agentic_dart/
├── archive/
│   └── poc/
│       └── pubdev_context/   ← archived PoC docs, ADRs, generated docs, issues
├── pubspec.yaml              ← Dart workspace root
└── packages/
        └── pubdev_context/       ← PoC base for new implementation
```



## License

MIT License — see individual package `LICENSE` files.