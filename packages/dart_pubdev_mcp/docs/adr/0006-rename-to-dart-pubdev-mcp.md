# Rename `pubdev_context` to `dart_pubdev_mcp` / `dart-pubdev-explorer` at V1 cutover

`pubdev_context` is a published, verified pub.dev package (194 popularity) built as a PoC. The V1 architecture in `docs/prd_release.md` supersedes the PoC's interfaces entirely, and the PoC name no longer fits the product being built. pub.dev has no in-place rename, so this is a one-way move: publishing under a new name, with the old listing left behind as a pointer.

## Context

Two constraints shaped this decision:

- **Dart package names must be `lowercase_with_underscores`** — pub.dev rejects hyphens. Any hyphenated name under consideration cannot be the `pubspec.yaml` package name.
- **The package name and the MCP identity were already two different strings.** `pubdev_context` is the pub.dev package name, but the `Implementation.name` sent in the MCP handshake (`lib/src/server.dart`) and the `.mcp.json` server key are already `dart_pubdev` — distinct from the package name. This precedent is what makes a package-name/display-name split unsurprising rather than an inconsistency to "fix."

## Decision

Three identities, three names:

| Identity | New name | Constraint driving it |
|---|---|---|
| pub.dev / `pubspec.yaml` package name | `dart_pubdev_mcp` | must be a legal Dart identifier |
| MCP `Implementation.name` (handshake) + `.mcp.json` server key | `dart-pubdev-explorer` | free-form; optimized for recognizability in a client's server list |
| CLI executable | `dart-pubdev-explorer` | matches the display name a user already sees in their MCP client, not the package they installed |

- *Rejected — one name for everything:* impossible given the hyphen constraint above; forced the split.
- *Rejected — executable matches package name (`dart_pubdev_mcp`) instead of display name:* would mean the command a user types on their terminal doesn't match what they see labeled in Claude Desktop/Code — display-name recognizability won out.

**Migration:** publish `dart_pubdev_mcp` fresh at `0.5.0` — not a continuation of the `0.x` PoC line's numbering, and deliberately kept below `1.0.0` because the V1 tool surface is still pre-stable under semver (see Revision note below). Mark `pubdev_context` discontinued on pub.dev with a description/README pointer to `dart_pubdev_mcp`. Existing `pubdev_context` installs keep working (nothing is unpublished); new users and search traffic get redirected.

**Revision (2026-07-14):** the version-number decision above originally targeted `1.0.0`, reasoned as a "clean break" that would signal V1 as the definitive architecture, not incremental. That rationale is superseded: `0.y.z` under semver is an explicit signal that the public API isn't yet considered stable, which is a more honest fit for where the V1 tool surface actually is. Everything else in this ADR (the three-identity naming decision, the never-unpublish/discontinue-with-pointer migration mechanics) is unchanged.

**Timing:** enacted at V1 cutover, not immediately. The current `packages/pubdev_context/` code is PoC-derived and still being rewritten to the V1 architecture — renaming it now would mean renaming code out from under itself and then living with the churn twice. Forward-looking docs (`docs/prd_release.md`, `CLAUDE.md` Status, `README.md`) adopt the new names now since they describe the target V1 state; the actual directory, `pubspec.yaml`, executable, and publish step wait for cutover. Archived PoC material (`archive/poc/pubdev_context/`) is frozen and untouched.

## Consequences

- Until cutover, the working directory (`packages/pubdev_context/`), package name, and executable remain `pubdev_context` even though docs describe the future state as `dart_pubdev_mcp` / `dart-pubdev-explorer`. This is a deliberate, temporary doc/code naming gap — not drift to be "fixed" early.
- At cutover: rename the directory, `pubspec.yaml` `name:`/`executables:`, `bin/` entry point, `Implementation.name` in `server.dart`, and `.mcp.json`; publish `dart_pubdev_mcp@0.5.0`; discontinue `pubdev_context` on pub.dev.
- No change to the monorepo name (`agentic_dart`) or repository location — only the package/executable/MCP-identity layer is renamed.
