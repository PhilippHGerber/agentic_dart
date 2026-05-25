# Nested error schema with SCREAMING_SNAKE_CASE codes

All tool errors use MCP `CallToolResult` with `isError: true` and a single JSON text block shaped as:

```json
{
  "error": {
    "code": "AMBIGUOUS_SYMBOL",
    "message": "Human-readable explanation.",
    "retryable": true,
    "suggestion": "Actionable hint.",
    "suggestedNextStep": { "tool": "find_symbols", "arguments": { "package": "…", "query": "…" } },
    "details": { }
  }
}
```

`suggestedNextStep` is optional (omitted when no obvious next tool call exists). `details` carries error-specific data (e.g. `candidates` for `AMBIGUOUS_SYMBOL`).

## Considered options

**Flat PoC schema:** `{ "error": "code", "message": "…", "suggestion": "…", "alternatives": [] }`. Rejected: the flat `alternatives` field is not generalisable across error types; there is no machine-readable `retryable` flag; the flat `error` string collides with the JSON key name making it confusing to parse; and the lack of `suggestedNextStep` forces the LLM to infer the next call from prose.

**Nested PRD schema (adopted):** Wraps all error fields under `error: {}`. `SCREAMING_SNAKE_CASE` codes are visually unambiguous in LLM context windows. `retryable` lets an automated agent decide whether to retry without text-parsing. `suggestedNextStep` provides a ready-to-fire tool call, eliminating a reasoning step.

## Consequences

Breaking change from the PoC error format. The PoC codes `class_not_found` and `method_not_found` are collapsed into `SYMBOL_NOT_FOUND` (the concept is the same; the old names were artefacts of `get_method_body`'s class+method input model).
