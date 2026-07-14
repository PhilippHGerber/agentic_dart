# Handler-layer caching via a `KeyedCache` facade and a `CacheRegistry`

The get→miss→log→fetch→set→skip-errors dance is duplicated across all 12 tool handlers, each building its own cache-key string and pairing its own TTL constant. Several handlers share a `ResponseCache` store by hand-agreeing an inline key format, so a key-format drift between two callers is a silent cache miss or collision that nothing catches.

We replace that pattern with a single deep module — `KeyedCache<Id, T>` — one instance per cached artifact, owned by a `CacheRegistry`. Handlers call `resolve(id)` with a typed identity; the key format, TTL, single-flight, and skip-on-failure all live behind the interface.

## Context

Twelve handlers and two resource handlers each re-implement the same caching ritual over an injected `ResponseCache<T>`. Four stores are shared by two or more callers that must independently agree on an inline key format:

| Store | Callers | Key | Drift status |
|---|---|---|---|
| `apiIndexCache` | 4 | `$prefix:$pkg:$ver` (shared prefix const) | partially guarded |
| `packageCache` | 2 | `package:$name:$ver` vs `package:$name:` | **mismatched today** |
| `sourceFilesCache` | 2 | inline `source:$name:$version` in each file | latent |
| `astCache` | 2 | inline `ast:$name:$ver:$path` (doc duplicated) | latent |

`get_package` caches `package:http:1.6.0`; `compare_packages` caches `package:http:` — the same `PackageDetail`, two entries, two fetches, in the same store. `sourceFilesCache` is worse: its two callers disagree on single-flight — `get_source_slice` stores an in-flight `completer.future`, `get_throw_statements` stores a resolved `Future.value`. In fact 8 of 10 store-sites pass `Future.value(...)`, so the stampede protection `ResponseCache` advertises is not actually exercised on most paths.

The store itself (`ResponseCache<T>`) is deep and well-tested — TTL eviction, proactive timers, Zone-correlated Wire Trace hits, an `entries` snapshot consumed by autocomplete. The shallowness is one tier up, in the access pattern the handlers repeat.

## Decision

Introduce `KeyedCache<Id, T>` in `lib/src/cache/`, one instance per artifact, assembled by a `CacheRegistry`.

- **One deep module keyed by typed identity.** `resolve(Id) → PubDevResult<T>` is the whole call site; the fetch closure is pre-wired at construction. `Id` is a typed record (`(name:, version:)`, a query tuple for search, `(name)` for versions), so a key collision is a type error rather than a silent miss. The get/miss/set/log dance is implemented and tested once.
  - *Rejected — a `getOrFetch(cache, key, ttl, fetch)` combinator:* collapses the dance but the caller still passes a raw string key and picks the TTL, so the four `apiIndexCache` callers can still drift. It does not give an artifact a single key-owner, which is the actual correctness target.
  - *Rejected — a hand-written facade class per artifact:* same locality, but re-scatters the dance across ~10 near-identical classes instead of concentrating it in one generic implementation.

- **Wraps `ResponseCache<T>`, does not replace it.** `KeyedCache` holds a private `ResponseCache<T>` as its storage tier and adds identity→key derivation, the `PubDevResult`-aware single-flight `resolve`, and two cache-only accessors autocomplete needs (`peek(Id)` and `entries`). `ResponseCache` keeps the "public interface will not change" promise in its doc.
  - *Rejected — fold TTL/timer/tracing into `KeyedCache` and retire `ResponseCache`:* re-derives working, tested machinery for no gain and breaks that promise.

- **Cacheability rides the existing `PubDevResult<T>` envelope.** The fetcher returns `Future<PubDevResult<T>>`; success caches, failure passes through uncached. The local AST parse wraps in an always-`PubDevSuccess`; meta maps an HTTP error to a `DomainError`.
  - *Rejected — a cache-native `CacheOutcome<T>` (`Cacheable`/`Uncacheable`):* conceptually purer, but adds a type and forces a `PubDevResult → CacheOutcome` adapter at every call site. `KeyedCache` lives only in this server, so coupling it to `PubDevResult` costs nothing in reuse and lets `resolve` drop straight into each handler's existing `switch`.

- **Real single-flight.** `KeyedCache` stores the in-flight future (completer + invalidate-on-failure) so concurrent `resolve` calls for the same `Id` share one fetch and failures are never cached. An agent turn firing `browse_api_symbols` + `find_symbols` + `get_symbol_documentation` at one package collapses to a single api-index fetch. This also makes the two inconsistent `sourceFilesCache` callers consistent.
  - *Rejected — keep await-then-cache-success:* preserves today's inconsistency and issues redundant concurrent fetches for the hottest shared entries.

- **A `CacheRegistry` owns construction and wiring.** It takes the `PubDevClient` (plus trace and the meta HTTP client) and constructs every `KeyedCache` with its `keyOf`, `ttl`, and `fetch` closure — so all key formats, TTLs, and fetch wiring live in one file. `PubMcpServer`'s constructor collapses from 11 cache parameters to one; handlers still receive their single facade.
  - *Rejected — build facades inside the server:* bleeds cache-construction concerns into `PubMcpServer`. *Rejected — inject 11 facades:* keeps the wiring sprawl.

- **`packageCache` unifies on `(name, version)`.** `compare_packages` gains a `resolveLatestStable(name)` — now a Package Info Cache hit under ADR-0004, not a pub.dev round-trip — so it shares `get_package`'s `(http, 1.6.0)` entry. The double-entry and the double-fetch both die. A resolve failure demotes into compare's `errors` map exactly as a `getPackage` failure does today.
  - *Rejected — keep "latest" as a distinct cached identity (a sentinel):* leaves `(http, latest)` and `(http, 1.6.0)` as separate entries, so the redundancy survives.

All handler caches migrate in one sweep.

## Consequences

- Handler tests stop asserting cache-key strings; they inject a real `KeyedCache` wired to a fake client, exercising the actual caching path. `KeyedCache`'s single-flight and skip-on-failure logic is tested once at its own interface.
- `KeyedCache` is coupled to `PubDevResult<T>` by design; it is an internal `lib/src/` module, never a published cache primitive. The low-level `ResponseCache` stays domain-agnostic.
- No Wire Trace change: a hit is still `ResponseCache.get()` returning a live entry, logged as before. No new domain term is born, so `CONTEXT.md` is untouched.
- ADR-0004's in-`PubDevClient` Package Info Cache is unaffected. The stale `// see plan W4` comment in `get_package.dart` is deleted.
- `astCache` and `metaCache` migrate too: the AST parse never fails in a cache sense (always-success), and `metaCache` keeps its fixed keys but now flows through the same facade.
