# Canonical Schema Harmonization Across All 19 Tools

`dart-pubdev-explorer` establishes an uncompromising, symmetric, and predictable canonical schema across all 19 tools in `dart_pubdev_mcp`. In this v0.x breaking redesign, parameter and property names in Call JSON (`inputSchema`) and Return JSON (`outputSchema` / structured response) are harmonized so that every concept has exactly one name, return fields mirror input fields symmetrically, outputs compose directly into downstream tools without translation, and 100% of tools declare formal output schemas.

## Context

Over successive development iterations, slight naming discrepancies and asymmetries emerged across the tool surface:
- File locations were referred to as `file` in `get_source_slice`/`get_sdk_source_slice`, `files` in `list_package_source_files`/`list_sdk_source_files`, `file` in grep matches and throw statements, but `path` in other contexts.
- Return JSON omitted primary identity fields in certain tools (`package` was missing from `get_changelog`, `sdk` was missing from `get_sdk_release_notes`).
- `search_packages` returned a bare JSON array `[...]` and was exempt from declaring an `outputSchema`, making it the only tool in the server without formal `structuredContent` validation.
- `get_throw_statements` and `get_sdk_throw_statements` returned `{ file, symbol, thrownType, context }` without line numbers, requiring callers to guess or grep to find the exact line before slicing with `get_source_slice`.

## Decision

### 1. The Path Invariant (`path` & `paths`)
- Source file paths are exclusively named `path` (for a single file) or `paths` (for a list of files).
- The words `file` and `files` are prohibited for source location parameters and return properties.
- `get_source_slice` and `get_sdk_source_slice` require `path` in `inputSchema` and return `path` in `outputSchema`.
- `list_package_source_files` and `list_sdk_source_files` return `paths` (sorted alphabetically).
- `grep_package_source` and `grep_sdk_source` return `matches[].path`.
- `get_throw_statements` and `get_sdk_throw_statements` return `throws[].path`.
- Filename extension filters remain named `fileExtension` to distinguish file extension filters (`.dart`, `.yaml`) from Dart language `extension` declarations.

### 2. Location Precision in Throw Statements (`line`)
- `get_throw_statements` and `get_sdk_throw_statements` include `line: int` (1-based line number) in every throw record: `{ path, line, symbol, thrownType, context }`.
- Enables direct pipelining: `get_source_slice(path: throwItem.path, lineStart: throwItem.line - 5, lineEnd: throwItem.line + 5)`.

### 3. Call $\leftrightarrow$ Return Symmetry & Identity-Only Echoing
- Target identity and scope are echoed symmetrically in Return JSON:
  - `get_changelog` returns `package` along with `resolvedVersion` and `entries`.
  - `get_sdk_release_notes` returns `sdk` along with `resolvedVersion` and `entries`.
  - `grep_package_source` returns `package`, `resolvedVersion`, `pattern`.
  - `grep_sdk_source` returns `sdk`, `resolvedVersion`, `pattern` (and conditionally `library` or `package`).
- Only primary scope/identity fields are echoed. Optional filter constraints (`directory`, `fileExtension`, `limit`, `regex`, `caseInsensitive`) are omitted from Return JSON to minimize token payload overhead.

### 4. Full `outputSchema` Coverage (`search_packages` Object Envelope)
- `search_packages` wraps its return array in a top-level JSON object `{ "packages": [ ... ] }`.
- `searchPackagesTool` declares a complete `outputSchema` with required/optional fields matching `PackageSummary`.
- All 19 tools in the server now declare formal `outputSchema` definitions.

### 5. Strict Input Validation
- Handlers strictly validate input arguments against `inputSchema`.
- No transitional fallbacks (e.g. `args['path'] ?? args['file']`) are supported in handler code, ensuring callers and LLMs adhere strictly to the published schema.

## Considered options

- **Retaining `search_packages` bare array exemption**: Rejected. Leaving one tool without an `outputSchema` breaks uniform client validation and makes MCP response processing inconsistent.
- **Echoing all input parameters in Return JSON**: Rejected. Echoing secondary filter arguments (`limit`, `directory`, `caseInsensitive`) increases response tokens without adding value for downstream tool composition.
- **Renaming `fileExtension` to `extension`**: Rejected. In Dart, `extension` is an overloaded keyword denoting extension methods/types (queried via `browse_api_symbols(kind: "extension")`). `fileExtension` clearly specifies a file suffix.
- **Transitional parameter aliasing (`file` fallback)**: Rejected. In v0.x, a clean break ensures prompt clarity and prevents lingering legacy debt.

## Consequences

- **Breaking change**: Bumps package version from `0.9.0` to `0.10.0`.
- All MCP clients and prompt definitions must use `path` instead of `file`, expect `paths` instead of `files`, and parse `search_packages` as `{ packages: [...] }`.
- Full output schema conformance tests validate all 19 tools.
- Direct composition workflows (`list_*` $\to$ `get_*_source_slice`, `grep_*` $\to$ `get_*_source_slice`, `get_*throw_statements` $\to$ `get_*_source_slice`) operate with zero field translation.
