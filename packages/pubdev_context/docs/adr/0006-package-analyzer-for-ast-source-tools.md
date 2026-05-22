# Structural source queries use `package:analyzer`, not regex or subprocess

`get_method_body` and `get_throw_statements` require extracting code structure from raw Dart source: precise method body boundaries and the set of `throw` expressions within a scoped region. Two lighter alternatives were considered before accepting the `package:analyzer` dependency.

**Considered options:**

- **Regex / heuristic text scanning** _(rejected)_: locate method bodies by matching the signature pattern and tracking brace depth; find `throw` keywords with a simple text search. Zero new dependencies. Rejected because both approaches are fragile: brace tracking fails on string interpolation and nested closures; `throw` in string literals and comments produces false positives. The error cases are silent — the tool returns wrong data rather than an error, which is worse than a `DomainError`.
- **`dart pub unpack` subprocess** _(rejected)_: shell out to produce a temp directory, run an analysis script. Rejected for the same reasons as ADR-0005: introduces process-spawning and temp-directory lifecycle management that breaks the in-process, pure-HTTP architecture.
- **`package:analyzer` with `parseString()`** _(chosen)_: parse each source file in memory from the already-cached tarball content. Uses only the unresolved AST — `parseString()` from `dart/analysis/utilities.dart` — which is sufficient for all structural queries (member boundaries, throw expressions, type names as declared). No filesystem access, no subprocess, no full analysis context required.

The `parseString()` surface has been stable across Dart SDK versions for years and is the standard approach for single-file structural analysis in the Dart ecosystem. The transitive dependency graph is large but the capability is qualitatively different from what regex can provide.

**Consequences:** `package:analyzer` is added as a dependency, significantly increasing install size. **AstSnapshot** results are cached at `ast:<name>:<version>:<filepath>` with a 1-hour TTL, sharing the existing source tarball cache layer. Cross-file type resolution is intentionally out of scope — types from other packages appear as unresolved names in the AST, which is acceptable for the structural queries these tools perform.
