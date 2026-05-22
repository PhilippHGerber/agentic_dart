# `get_throw_statements` and `get_method_body` scope: class optional when a specific function is named

The FR proposed `class` and `method` as optional filters, allowing package-wide throw scanning when both are omitted. Package-wide scanning was rejected on performance grounds. The initial decision required `class` in both tools. A gap review against real pub.dev index data (the `http` package) revealed that top-level functions — `http.get`, `http.post`, `http.read` — are primary API entry points with `type: function` and no enclosing class. Requiring `class` made both tools unreachable for that entire category.

**Considered options:**

- **`class` and `method` both optional (package-wide default)** _(rejected)_: a package-wide scan calls `parseString()` on every Dart file. For packages with 50–100 source files this is a significant burst of CPU and memory with an unpredictable response size.
- **`class` required, `method` optional** _(rejected after gap review)_: correctly bounds class-scoped queries but excludes top-level functions entirely. Agents fall back to `get_package_source_file` (whole-file dump) for any top-level API — which is the token waste both tools exist to avoid.
- **`class` optional; when omitted, `method` required and treated as a top-level function name** _(chosen)_: the scope remains bounded in all valid cases. Three valid call shapes: (class only) → all throws in the class; (class + method) → throws in one class method; (method only, no class) → throws in one top-level function. The invalid shape (neither class nor method) is rejected with a `DomainError(invalid_input)`.

**Consequences:** The "no class + specific method" path locates the function via the dartdoc API index (`type: function`, `qualifiedName` suffix matching per ADR-0007) to find the correct source file, then visits only that function node in the **AstSnapshot**. Performance remains bounded. For `get_method_body`, the same three-shape contract applies: `class` + `method`, or `method` alone for top-level functions. Package-wide scanning remains unsupported.
