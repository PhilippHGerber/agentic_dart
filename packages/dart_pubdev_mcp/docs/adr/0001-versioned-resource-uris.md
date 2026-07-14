# Versioned resource URIs require explicit `@{version}` segment

All package resource URIs use the form `pub://package/{name}@{version}/{resource}` (e.g. `pub://package/http@1.2.0/readme`). The versionless form `pub://package/{name}/{resource}` is not supported. `latest` is a valid value for `version` and resolves to the Latest Stable Version at request time.

## Considered options

**Dual templates (versionless + versioned):** Support both `pub://package/{name}/readme` and `pub://package/{name}@{version}/readme`. Rejected because it doubles the number of resource templates (5 → 10), duplicates version-resolution logic across both handlers, and hides the resolved version from the LLM when the versionless form is used.

**Always-versioned:** Require `@{version}` in every URI, accept `latest` as a special alias. Single template set, single code path, and the `[Resolved Version: x.y.z]` header in every response explicitly grounds the LLM for all follow-up calls.

## Consequences

Breaking change from the PoC URI scheme — acceptable because the PRD explicitly does not require PoC compatibility.
