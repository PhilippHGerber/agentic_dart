# pubdev_context

An MCP server that bridges LLM agents to the pub.dev public REST API. It exposes Dart/Flutter package data as structured tools, with all errors formatted for LLM consumption.

## Language

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

## Relationships

- A **PackageDetail** is a strict superset of **PackageSummary** data
- Every failed **Tool** response carries exactly one **DomainError**
- **activeMaintenance** is computed from `daysSinceUpdate` and `pubPoints` — it is never stored on pub.dev or fetched via a separate call

## Example dialogue

> **Dev:** "If the score endpoint returns a malformed date, does `activeMaintenance` go wrong?"
> **Domain expert:** "No — `activeMaintenance` is derived from `daysSinceUpdate`, which is computed by `_daysSince()`. That function returns `0` on a parse failure independently of the `publishedAt` field on **PackageDetail**. The two are separate paths."

> **Dev:** "Should a **Tool** throw if pub.dev returns a 500?"
> **Domain expert:** "Never. The **Tool** catches that in `RetryPolicy`, exhausts its retries, and returns a **DomainError** with `error: service_unavailable` and a `suggestion` the LLM can act on."

## Flagged ambiguities

- "package info" was used loosely to mean both **PackageSummary** and **PackageDetail** — these are distinct types with different field sets and different call sites.
