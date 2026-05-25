# Nested error schema with SCREAMING_SNAKE_CASE codes

All tool errors use MCP `CallToolResult` with `isError: true` and a single JSON text block shaped as:

```json
{
  "error": {
    "code": "AMBIGUOUS_SYMBOL",
    "message": "Human-readable explanation.",
    "retryable": true,
    "suggestion": "Actionable hint.",
    "suggestedNextStep": { "tool": "search_api_symbols", "arguments": { "package": "…", "query": "…" } }
  }
}
```

Fields:

| Field | Type | Required | Notes |
|---|---|---|---|
| `code` | string | ✅ | `SCREAMING_SNAKE_CASE` — see code registry below |
| `message` | string | ✅ | Human-readable explanation of what went wrong |
| `retryable` | boolean | ✅ | `true` for transient errors; derived from code, not caller-supplied |
| `suggestion` | string | ✅ | Actionable advice for the caller |
| `suggestedNextStep` | object | optional | Ready-to-fire tool call hint: `{ "tool": "…", "arguments": { … } }` |
| `details` | object | optional | Error-specific structured data (e.g. `candidates` for `AMBIGUOUS_SYMBOL`) |

`suggestedNextStep` and `details` are omitted from the JSON entirely when not applicable — they are never present as `null` or `{}`.

## Code registry

| Code | Retryable | Meaning |
|---|---|---|
| `PACKAGE_NOT_FOUND` | no | Package does not exist on pub.dev |
| `RATE_LIMITED` | **yes** | pub.dev returned HTTP 429 |
| `SERVICE_UNAVAILABLE` | **yes** | pub.dev returned HTTP 5xx |
| `REQUEST_TIMEOUT` | **yes** | Request did not complete within the allotted time |
| `UNEXPECTED_RESPONSE` | no | Response body could not be parsed (unexpected shape or encoding) |
| `NO_DOCUMENTATION` | no | Changelog contains no recognisable version headings |
| `DOCUMENTATION_NOT_FOUND` | no | Dartdoc documentation was not found for one or both requested versions |
| `INVALID_ARGUMENT` | no | A supplied parameter is outside the accepted range or format |
| `SYMBOL_NOT_FOUND` | no | Requested symbol (class, method, constructor, accessor, top-level function) not found |
| `AMBIGUOUS_SYMBOL` | no | Symbol name matches more than one entry; `details.candidates` carries the list |
| `NO_RESULTS` | no | Query or type filter yields zero matching symbols |
| `EXAMPLE_NOT_FOUND` | no | Package example page is absent or empty |
| `SOURCE_FILE_NOT_FOUND` | no | Requested path is not present in the package tarball |
| `PACKAGE_TOO_LARGE` | no | Tarball download exceeded the per-package size limit |

## Considered options

**Flat PoC schema:** `{ "error": "code", "message": "…", "suggestion": "…", "alternatives": [] }`. Rejected: the flat `alternatives` field is not generalisable across error types; there is no machine-readable `retryable` flag; the flat `error` string collides with the JSON key name making it confusing to parse; and the lack of `suggestedNextStep` forces the LLM to infer the next call from prose.

**Nested PRD schema (adopted):** Wraps all error fields under `error: {}`. `SCREAMING_SNAKE_CASE` codes are visually unambiguous in LLM context windows. `retryable` lets an automated agent decide whether to retry without text-parsing. `suggestedNextStep` provides a ready-to-fire tool call, eliminating a reasoning step.

## Consequences

Breaking change from the PoC error format. The PoC codes `class_not_found` and `method_not_found` are collapsed into `SYMBOL_NOT_FOUND` (the concept is the same; the old names were artefacts of `get_method_body`'s class+method input model).
