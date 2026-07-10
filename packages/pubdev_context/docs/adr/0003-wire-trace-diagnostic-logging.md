# Wire Trace diagnostic logging

To make the server's otherwise-invisible traffic observable, we add a **Wire Trace**: a human-readable, chronological file log of every message crossing the server's two boundaries — the LLM boundary (inbound tool/resource calls and the results returned) and the pub.dev boundary (outbound HTTP requests and their responses) — with a per-request Correlation Id linking them. It is a **separate subsystem** from the MCP `log()` notification mechanism, is **opt-in / default off**, and propagates its Correlation Id via a Dart `Zone`.

## Context

`pubdev_context` runs as a **stdio** MCP server: stdout is owned by the JSON-RPC protocol, so nothing human-readable may be written there. The only existing logging is dart_mcp's `LoggingSupport.log()`, which sends `notifications/message` back to the LLM host — visibility depends entirely on the client and is gated by a level the client can change. In practice the operator cannot see what the LLM asks, what the server asks pub.dev, or what it answers. `PubDevClient` had no logging at all.

## Decision

Three choices worth recording, each with a rejected alternative:

1. **A dedicated file subsystem, not the MCP `log()` channel.** The Wire Trace writes a file the server owns (per-session file, `keep-last-10` retention), in human-first pretty text (never JSON). The existing `log()` / `--log-level` stay untouched and orthogonal.
   - *Rejected — reuse `log()`/`notifications/message`:* it is the very thing that is invisible; visibility is client-dependent, and a client shouldn't be able to silence the operator's diagnostics by lowering a level.
   - *Rejected — stderr only:* location/rotation are out of our control and lines interleave with framework noise; a file we own is stable and greppable.

2. **Correlation Id propagated via a Dart `Zone`.** The LLM boundary is captured by one central dispatch wrapper (installed at `registerTool`/`addResource`), which assigns a monotonic Correlation Id and runs the call inside a `Zone` carrying it. `PubDevClient` reads the id from `Zone.current`.
   - *Rejected — thread an id parameter through every method:* would change the signature of all 13 tool handlers and every `PubDevClient` method for a cross-cutting concern; the Zone keeps the id ambient with no signature churn and survives interleaved concurrent requests correctly.

3. **Opt-in, default off.** Enabled by `--wire-trace` (env `pubdev_context_WIRE_TRACE`). When absent, the wrapper, the Zone, and the client logger are not installed — zero overhead.
   - *Rejected — on by default:* this is a published package; silently writing verbose trace files to every downstream user's disk is surprising. The operator enables it once in their own client config.

## Consequences

- `PubDevClient` gains an injected (nullable) logger and reads the ambient Correlation Id; when tracing is off it is never constructed.
- The Wire Trace is **best-effort and must never break the server**: open failure logs one stderr warning and disables tracing; mid-session write failure drops tracing silently. It flushes per line so `tail -f` is live and the last line before a crash survives.
- Bodies are logged as size-capped previews (`--wire-trace-max-preview`, default 2048 bytes, `0` = metadata only); tarball payloads are never dumped; HTML endpoints log the converted-markdown preview only.
- Out of scope for the introducing release: NDJSON sink, size-based rotation, header logging, configurable retention.
