# Package Info Cache lives in `PubDevClient`

`PubDevClient` gains a **Package Info Cache**: an in-memory, TTL-bound, single-flight cache for the raw `GET /api/packages/{name}` response, keyed by package name and checked transparently inside the client before any request to that endpoint. It sits beside the already-injected `TarballDiskCache` rather than as a new handler-layer resolver.

## Context

`GET /api/packages/{name}` returns a package's full metadata (every version included) and is the endpoint used to resolve the Latest Stable Version. Every handler that accepts an optional `version` argument calls `PubDevClient.resolveLatestStable` before doing anything else — and `resolveLatestStable` has no cache of its own, so it always re-fetches this endpoint from pub.dev. `getPackage`, `listVersions`, and `search`'s per-result enrichment (`_fetchSummary`) call the identical endpoint again for their own purposes. Within a single agent session working one package across several tools, this endpoint is fetched from pub.dev once per tool call — never served from cache — even though the underlying data changes on the timescale of package releases, not seconds.

This was reviewed once already (`issues/pubdev-context-v1/05-latest-stable-plan.md`, decision **W4**) and left as WON'T FIX, on the grounds that a structural fix meant threading the already-resolved package detail from `resolveLatestStable` through into each handler's subsequent fetch — real complexity for, it was assumed, "one lightweight JSON GET." A Wire Trace capture of a real three-tool session against one package showed the actual cost: the same 27.3 KB payload fetched four times in under two minutes, zero cache hits, one fetch alone taking 493 ms.

## Decision

Add a `ResponseCache<Map<String, Object?>>` **inside `PubDevClient`**, keyed by package name, TTL `kPackageMetadataTtl` (15 min — already the documented TTL for this same endpoint via `kPackageVersionsTtl`'s doc comment). `resolveLatestStable`, `getPackage`, `listVersions`, and `search`'s per-result enrichment all route through one private fetch helper that checks this cache first. No handler code changes; no threading of resolved data anywhere — the cache sits transparently below every caller.

- *Rejected — a shared resolver object at the handler layer* (its own `ResponseCache`, injected into all eight handlers that call `resolveLatestStable`, in place of calling `PubDevClient` directly): keeps `PubDevClient` cache-free and all TTL policy in the handler layer, consistent with every other cache in the codebase. Rejected because it only fixes the *version-resolution* redundancy — it does nothing for `getPackage`'s own internal double-fetch of the same endpoint, or `search`'s enrichment, unless those are also rewritten to consume the resolver's cached data instead of calling `PubDevClient` methods wholesale. That rewrite is exactly the "thread the resolved detail through" complexity W4 rejected as too risky the first time.
- *Precedent*: `PubDevClient` already owns and consults a cache — the injected `TarballDiskCache`, checked directly inside `getPackageSourceFiles`. This is the same shape of decision, not a new kind of one.

## Consequences

- `PubDevClient` is no longer a purely stateless-per-call HTTP gateway; its class doc must say so (it already documents the tarball cache the same way).
- A newly published package version can take up to 15 minutes to become visible as the Latest Stable Version within a session — unchanged risk profile from the existing `kPackageMetadataTtl`/`kPackageVersionsTtl` policy elsewhere in the codebase, not a new one.
- Failed fetches (404, transient errors) are never cached, per the existing cache-poisoning fix precedent (`05-latest-stable-plan.md` P0.1–P0.3).
- `issues/pubdev-context-v1/05-latest-stable-plan.md`'s W4 entry is left as-is (closed historical record) — this ADR is the current, authoritative statement; implementation is tracked in `issues/package-info-cache/`.
