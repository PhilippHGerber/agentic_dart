# pubdev_context

`pubdev_context` is an archived proof of concept retained in this repository as
reference code.

The original package documentation was moved to
`../../archive/poc/pubdev_context/packages/pubdev_context/README.md`.

The associated ADRs, changelog, generated docs, and decision history were
archived under `../../archive/poc/pubdev_context/`.

These materials are intentionally historical and outdated. They are available
for reference, but they should not be treated as active constraints on the real
product.

## Wire Trace

The **Wire Trace** is an opt-in, human-readable diagnostic log of everything
crossing the server's two boundaries — the **LLM boundary** (the tool calls and
resource reads the agent makes, and the results it gets back) and the **pub.dev
boundary** (the HTTP requests the server sends upstream and the responses it
receives). It is written for "open it and understand," not for machine parsing.
It is a separate subsystem from the MCP `log()` / `--log-level` channel, which is
left completely untouched.

### Enabling it

Add `--wire-trace` to the server invocation in your MCP client config (or set
the environment variable). It is **off by default** — installing the server
never writes files to disk unless you opt in.

```jsonc
{
  "mcpServers": {
    "dart-pubdev-explorer": {
      "command": "dart-pubdev-explorer",
      "args": ["--wire-trace"]
    }
  }
}
```

Equivalently: `dart_pubdev_mcp_WIRE_TRACE=1`.

### Configuring it

For each knob a CLI flag wins over its environment variable, which wins over the
default:

| Flag | Environment variable | Default | Purpose |
| --- | --- | --- | --- |
| `--wire-trace` | `dart_pubdev_mcp_WIRE_TRACE` | off | Enable the trace. |
| `--wire-trace-dir <path>` | `dart_pubdev_mcp_WIRE_TRACE_DIR` | `<cache-dir>/wire-trace` | Directory the per-session files are written to. |
| `--wire-trace-max-preview <bytes>` | `dart_pubdev_mcp_WIRE_TRACE_MAX_PREVIEW` | `2048` | Cap on each logged body preview. `0` = metadata-only (no bodies). |

`<cache-dir>` is the tarball cache directory (`--cache-dir`), which itself
defaults to `$XDG_CACHE_HOME/dart_pubdev_mcp` or `~/.cache/dart_pubdev_mcp`. So
with no other configuration the trace lands in `~/.cache/dart_pubdev_mcp/wire-trace/`.

### Locating the files

Each server run writes its **own** file, named by timestamp and process id:

```
wire-trace-20260709-140310-981-pid48213.log
```

Because the name sorts chronologically, **the trace for the run you just did is
simply the newest file**. Per-run files also keep concurrent server instances
from interleaving into one log. Old files are pruned automatically — the **last
10** are kept and the oldest beyond that are deleted. Lines are flushed as they
are written, so `tail -f` shows activity live and a crash preserves the last
line.

Tracing is strictly best-effort and never crashes the server: an unwritable
directory produces a single stderr warning and then runs with tracing disabled.

### Reading it

Every file opens with a session header recording the server version, pid, start
time, and effective config, followed by chronological event lines. Every line
carries a **Correlation Id** (`#001`, `#002`, …, a per-session counter) so you
can follow — or `grep` — one LLM request and all the pub.dev calls it triggered
as a single story, even when concurrent requests interleave.

```
════════════════════════════════════════════════════════════════════════
 Wire Trace — dart-pubdev-explorer 0.5.0
 session started 2026-07-09 14:03:10.981   pid 48213
 config: max-preview=2048B  concurrency=5  cache=~/.cache/dart_pubdev_mcp
════════════════════════════════════════════════════════════════════════

14:03:11.204  #001  ← LLM   tools/call  search_packages
                       args: {"query":"http client","limit":5}
14:03:11.205  #001    → pub  GET /api/search?q=http+client  [cache miss]
14:03:11.517  #001    ← pub  200 /api/search  (312 ms, 4.1 KB JSON)
                       body: {"packages":[{"package":"http"},{"package":"dio"},…  (truncated, 4.1 KB total)
14:03:11.518  #001    → pub  GET /api/packages/http  [cache miss]
14:03:11.860  #001    ← pub  200 /api/packages/http  (342 ms, 8.7 KB JSON)
14:03:12.010  #001  → LLM   result  search_packages   ok   (5 results, 806 ms, 6.2 KB)
                       body: [{"name":"http","likes":1234,…  (truncated, 6.2 KB total)

14:05:02.100  #002  ← LLM   tools/call  get_package
                       args: {"name":"htp"}
14:05:02.420  #002    ← pub  404 /api/packages/htp  (319 ms)
14:05:02.421  #002  → LLM   result  get_package   ERROR PACKAGE_NOT_FOUND  (321 ms)
                       error: {"code":"PACKAGE_NOT_FOUND","message":"Package not found on pub.dev.",…

14:06:10.320  #003    ⚠ pub  503 /api/search  (318 ms) — retry 1/3 in 500 ms
14:06:10.840  #003    → pub  GET /api/search?q=foo  [retry 1]

14:07:00.001  #004    ⚡ cache hit  get_package:http   (age 12s, no pub.dev call)
```

How to read the markers and lines:

- **`← LLM` / `→ LLM`** — a call coming in from the agent, and the result going
  back to it. The result line shows `ok` or `ERROR <CODE>`, the duration, and the
  result size.
- **`→ pub` / `← pub`** — a request the server sent upstream, and the response.
  A request is tagged `[cache miss]` when it followed a cache miss and `[retry N]`
  when it is a retry; a response shows status, latency, byte size, and content
  type.
- **`⚡ cache hit`** — an answer served from cache with no pub.dev call, with the
  entry's age. A cache **miss** is visible as the `→ pub` request that follows.
- **`⚠`** — a transient pub.dev failure, showing the attempt number and the
  backoff before the retry.
- **`args:` / `body:` / `error:`** — continuation lines carrying the full
  arguments, a truncated body preview, or the Tool Error payload. Previews over
  the cap are cut and annotated `… (truncated, <size> total)`; a cap of `0`
  omits bodies entirely.
- **HTML endpoints** (docs, changelog, example) log the converted-markdown
  preview only — never raw HTML — annotated with both sizes
  (`… KB HTML → … KB md`). **Tarball** downloads are logged as metadata only
  (size and extracted file count); archive bytes are never dumped.

Autocomplete (completions) traffic is deliberately excluded so it does not bury
the signal.