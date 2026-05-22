# pubdev_context

An MCP server that bridges LLM agents to the pub.dev public REST API. It exposes Dart/Flutter package data as structured tools, with all errors formatted for LLM consumption.

## Language

**Resource**:
A static MCP resource with a fixed URI (e.g. `pub://meta/scoring`). Registered with `addResource`. Always accessible without parameters — the URI is the complete address.
_Avoid_: static resource, endpoint, file

**ResourceTemplate**:
A parameterised MCP resource whose URI contains template variables (e.g. `pub://package/{name}/readme`). Registered with `addResourceTemplate`. Requires the caller to supply values for each `{variable}` segment.
_Avoid_: dynamic resource, parameterised endpoint

**ResourceHandler**:
The Dart class that implements resource read logic (`MetaResourcesHandler`, `PackageResourcesHandler`). Mirrors the **ToolHandler** pattern — no knowledge of how the resource is described to the LLM; it only processes `ReadResourceRequest` and returns `ReadResourceResult`.
_Avoid_: resource, handler, implementation

**Prompt**:
A pre-configured agent workflow registered with `addPrompt`. Exposes a named, parameterised workflow (e.g. `add-and-setup-package`) that an MCP client can surface to the user as a one-click action.
_Avoid_: template, workflow, slash command

**PackageSummary**:
The compact package view returned by search and compare operations. Derived fields (`activeMaintenance`, `isFlutterFavorite`) are computed inline from the API response — no extra HTTP calls.
_Avoid_: package info, package data, search result

**PackageDetail**:
The full package view returned by the `get_package` tool. A strict superset of **PackageSummary** data; also includes `dependencies`, `versionsRecent`, and `readmeExcerpt`.
_Avoid_: package info, full package, expanded package

**activeMaintenance**:
A derived boolean on **PackageSummary** and **PackageDetail**: `true` when `daysSinceUpdate < 365` OR `pubPoints >= 130`. Computed during model construction from the API response — never via an extra API call.
_Avoid_: maintained, active, recently updated

**DomainError**:
A structured failure value with four fields: `error` (machine-readable code), `message` (human explanation), `suggestion` (actionable recovery advice), and optional `docs` (URL). Designed specifically for LLM consumption — the LLM must be able to self-recover from any `DomainError` without external help.
_Avoid_: error, exception, failure message

**Tool**:
An MCP tool exposed to the LLM agent. Each tool maps to one or more pub.dev endpoints and always returns either a typed value or a **DomainError** — it never throws.
_Avoid_: command, endpoint, function

**ToolDefinition**:
The `Tool` + `ObjectSchema` pair that describes a tool to the MCP client. The complete LLM-facing contract: name, description, and parameter descriptions. Lives in `tool_definitions.dart` alongside the server instructions string.
_Avoid_: tool spec, tool schema, tool config

**ToolHandler**:
The Dart class that implements a tool's logic (`GetPackageHandler`, `SearchPackagesHandler`, etc.). Has no knowledge of how the tool is described to the LLM — it only processes `CallToolRequest` and returns `CallToolResult`.
_Avoid_: tool, handler, implementation

**HtmlToMarkdown**:
The single shared HTML-to-Markdown converter (`lib/src/data/html_to_markdown.dart`). All five pub.dev HTML extraction paths — symbol docs, changelog, full README, README excerpt, and package example — delegate here. Output is structured Markdown (headings, fenced code blocks, lists) optimised for LLM token efficiency and information density. Callers vary only the section-isolation parameters (`isolateTag`, `isolateClass`) and optional `maxChars` truncation. Tag-to-Markdown rules are defined once.
_Avoid_: HTML extractor, HTML parser, HTML stripper, plain-text extractor

**AstSnapshot**:
The parsed, unresolved representation of a single Dart source file, produced by `parseString()` from `package:analyzer`. Used by `get_method_body` and `get_throw_statements` for structural extraction (method bodies, throw statements) without cross-file type resolution. Cached separately from the raw source text under `ast:<name>:<version>:<filepath>` with a 1-hour TTL.
_Avoid_: AST, parsed file, analyzer result, resolved AST

**SymbolResolution**:
The internal two-pass lookup performed by `get_symbol_documentation` that maps a human-readable symbol name to a dartdoc `href` using the cached API index (`api_index:<package>`). Pass 1: exact match on the `name` field. Pass 2 (when pass 1 is ambiguous or empty): suffix match on `qualifiedName` with the library prefix stripped, allowing agents to pass qualified forms such as `"Client.send"` to disambiguate from `"BaseClient.send"`. When multiple matches survive both passes, the class-level entry is preferred; if exactly one class entry exists, it is used silently. A `DomainError` with an `alternatives` field is returned when multiple class entries exist, or when no class entry exists and multiple matches remain. Never exposed to the LLM agent — the agent supplies a name or qualified name, not an `href`.
_Avoid_: href lookup, index search, symbol search

## Relationships

- A **PackageDetail** is a strict superset of **PackageSummary** data
- Every failed **Tool** response carries exactly one **DomainError**
- **activeMaintenance** is computed from `daysSinceUpdate` and `pubPoints` — it is never stored on pub.dev or fetched via a separate call
- A **ResourceHandler** and a **ToolHandler** are parallel patterns — both process requests without knowing their LLM-facing description
- Every failed **Resource** read returns a structured **DomainError** payload (not an MCP protocol error)

## Example dialogue

> **Dev:** "If the score endpoint returns a malformed date, does `activeMaintenance` go wrong?"
> **Domain expert:** "No — `activeMaintenance` is derived from `daysSinceUpdate`, which is computed by `_daysSince()`. That function returns `0` on a parse failure independently of the `publishedAt` field on **PackageDetail**. The two are separate paths."

> **Dev:** "Should a **Tool** throw if pub.dev returns a 500?"
> **Domain expert:** "Never. The **Tool** catches that in `RetryPolicy`, exhausts its retries, and returns a **DomainError** with `error: service_unavailable` and a `suggestion` the LLM can act on."

## Flagged ambiguities

- "package info" was used loosely to mean both **PackageSummary** and **PackageDetail** — these are distinct types with different field sets and different call sites.
