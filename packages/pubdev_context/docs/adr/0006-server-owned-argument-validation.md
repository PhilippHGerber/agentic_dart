# Server-owned argument validation in the Tool Error dialect

Tool arguments are validated by the server itself, not by `dart_mcp`'s built-in `registerTool` validation. Every `registerTool` call passes `validateArguments: false`, and a central dispatch wrapper in `PubMcpServer` runs `tool.inputSchema.validate()` before invoking the handler, mapping any violation to an `INVALID_ARGUMENT` Tool Error (ADR-0002). **The `validateArguments: false` is deliberate — do not "fix" it back to the default.**

## Context

`dart_mcp` (0.5.2) validates arguments against a tool's `inputSchema` by default, but rejects violations as plain-text `Content` with `isError: true` — bypassing the nested error schema ADR-0002 promises for every failed tool call. Meanwhile several handlers re-checked schema-expressible rules inline (e.g. `browse_api_symbols` re-checked `limit > 25`, which the schema already caps) and emitted structured `INVALID_ARGUMENT` JSON. The result was two argument-error dialects, and which one an LLM saw depended on which path fired first.

## Considered options

- **Keep framework validation, accept two dialects:** smallest diff, but schema violations permanently bypass the ADR-0002 envelope — an automated agent cannot read `code`/`retryable`/`suggestion` off exactly the class of error it is most likely to trigger.
- **Handler-owned validation via a typed argument reader:** full envelope control, but re-implements what the schemas already declare; the accepted range then lives in both `tool_definitions.dart` (advertised to the LLM) and the handler (enforced), and the two can drift.
- **Server-owned validation at the central dispatch wrapper (adopted):** the schema stays the single source of validation truth, every argument error speaks the Tool Error dialect, and the mapping lives at the same choke point that already wraps handlers for Wire Trace.

## Consequences

- Handlers delete inline checks that merely restate the schema (type, required-presence, min/max, enum). Checks a JSON schema cannot express — empty-after-trim strings, at-least-one-of parameter pairs, `..` path segments — stay in the handlers, where tool-specific `suggestion` text belongs.
- The validation wrapper runs *inside* the `LlmBoundaryTracer` wrap, so rejected calls still appear in the Wire Trace with a Correlation Id.
- If `dart_mcp` ever changes its validation error format, this server is unaffected — it never uses that path.
