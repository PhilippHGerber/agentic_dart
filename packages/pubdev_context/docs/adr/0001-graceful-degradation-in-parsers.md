# Graceful degradation over fail-fast in API response parsers

The pub.dev API is not strictly versioned. Minor schema drift — a missing field, a null where a string was expected, a new list format — is expected over the life of this tool. We chose graceful degradation over fail-fast parsing: missing or malformed individual fields produce zero-values or `null`, not a `DomainError`. Only a structurally invalid top-level response (JSON that is not a map or list) triggers `unexpected_response`.

**Considered Options**:
- **Fail-fast**: throw a format exception on any unexpected field type, surface as `unexpected_response`. Keeps the LLM honest, but makes the tool fragile to innocent pub.dev schema changes.
- **Graceful degradation** _(chosen)_: return the best partial data available. A missing date becomes `null`. An unexpected list element is filtered out. The tool keeps working through minor API drift, and the LLM receives truthful-but-incomplete data rather than an error.

**Consequences**: Parsers must never silently substitute a plausible-looking value for missing data (e.g. epoch for a missing date). `null` is always preferable to a lie.
