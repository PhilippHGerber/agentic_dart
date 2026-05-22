# `get_class_members` and `get_class_hierarchy` dropped in favour of dartdoc-backed `get_symbol_documentation`

The FR for token-efficient agent workflows proposed four AST-based tools: `get_class_members`, `get_method_body`, `get_throw_statements`, and `get_class_hierarchy`. After redesigning `get_symbol_documentation` to accept symbol names directly (ADR-0007), two of the four became redundant.

**Why `get_class_members` is redundant:**
A dartdoc class page — fetched by `get_symbol_documentation("package", "ClassName")` — lists every constructor, field, and method with its full signature and doc comment. An AST-based `get_class_members` would reconstruct this from `parseString()`, but with two disadvantages: raw `///` doc comments instead of rendered prose, and cross-package types appearing as unresolved names (e.g., `PromptsApi` from another package has no href).

**Why `get_class_hierarchy` is redundant:**
Dartdoc pages explicitly list the superclass, implemented interfaces, and mixed-in types with resolved hrefs — because dartdoc ran full type resolution at publish time. An AST-based `get_class_hierarchy` delivers the same structural list but with unresolved cross-package type names, which is strictly worse for the agent's primary use case (deciding whether to follow up on another package).

**Considered options:**

- **Build both tools as AST-based** _(rejected)_: adds complexity and `package:analyzer` parse cost for every class query while delivering lower-quality data than the dartdoc path already provides.
- **Build both tools as dartdoc-scraped** _(rejected)_: would duplicate logic already present in the redesigned `get_symbol_documentation`. Two tools, same data source, same HTML scraping path.
- **Drop both; cover via `get_symbol_documentation`** _(chosen)_: zero additional tools, higher data quality (resolved types, rendered docs), no extra HTTP calls beyond what `get_symbol_documentation` already makes.

**Consequences:** `get_method_body` and `get_throw_statements` are the only AST-based additions. The `package:analyzer` dependency (ADR-0006) is justified by these two tools alone. If a package has no dartdoc output on pub.dev (rare), agents fall back to `get_package_source_file` — the AST tools remain available for implementation details regardless.
