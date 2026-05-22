# `get_symbol_documentation` accepts a symbol name, not an opaque `href`

The original `get_symbol_documentation` interface required an `href` field produced by a prior `search_api_symbols` call. This made the two-step sequence `search_api_symbols → get_symbol_documentation` mandatory even when the agent already knew the exact symbol name from the README or package docs. Feedback from 18 logged agent lookups showed that the majority of `search_api_symbols` calls were confirming names already known — pure overhead.

**Considered options:**

- **Keep `href` as the input, add `exact_match` flag to `search_api_symbols`** _(rejected)_: reduces wasted tokens in the search step but does not eliminate the mandatory two-step sequence. Agents still issue two calls for every known-name lookup.
- **Keep `href` as the input, add a parallel `name`-based overload** _(rejected)_: two parameter paths in one tool create ambiguity. Which takes precedence when both are supplied? The tool description becomes harder to follow.
- **Replace `href` with `symbol` (human-readable name), resolve internally** _(chosen)_: the handler performs **SymbolResolution** against the cached `api_index:<package>` entry. The agent supplies the name it knows; the `href` machinery is internal. Breaking change, but the server is pre-v1.0.

**Disambiguation rule (part of this decision):** When multiple index entries share the same `name`, the class-level entry is preferred. An agent asking for `Client` almost always wants the class overview page, which already lists all constructors, methods, and fields — making a follow-up call unnecessary. A `DomainError` with `alternatives` is returned only when no class-level entry exists and multiple matches remain.

**Qualified-name suffix matching (part of this decision):** The real dartdoc index stores method names as short unqualified strings — `name: "send"` appears for `BrowserClient.send`, `Client.send`, `BaseClient.send`, and `IOClient.send` simultaneously. An agent that needs a specific class's method cannot disambiguate using the short name alone. **SymbolResolution** therefore applies a two-pass strategy:
1. Exact match on the `name` field.
2. If ambiguous (multiple matches or zero), suffix match on `qualifiedName` with the library prefix stripped — e.g., agent input `"Client.send"` matches `"http.Client.send"` after stripping `"http."`.

This allows agents to pass qualified forms (`"Client.send"`, `"BaseClient.get"`) whenever a short name is ambiguous, without needing to know the library prefix.

**Consequences:** `search_api_symbols` (now `browse_api_symbols`) loses its role as a mandatory prerequisite and becomes a pure discovery tool for cases where the symbol name is not yet known. The `href` field is removed from the public tool interface entirely; it survives only as an internal implementation detail inside **SymbolResolution**.
