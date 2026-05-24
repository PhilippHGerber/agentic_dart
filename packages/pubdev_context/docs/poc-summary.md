# Proof of Concept pubdev_context  Summary

## Purpose

`pubdev_context` is a stdio MCP server that turns pub.dev into a structured
tool, resource, and prompt surface for AI agents. Instead of making an agent
scrape pub.dev pages ad hoc, the server wraps pub.dev REST endpoints, dartdoc
artifacts, rendered package pages, and published source tarballs behind typed
handlers with shared caches.

In practice, that gives agents a single MCP server for package discovery,
package evaluation, changelog analysis, API lookup, README and example access,
raw source inspection, and AST-precise source extraction.

## How the Server Is Structured

1. `bin/pubdev_context.dart` is the executable entrypoint. It parses CLI and
   environment configuration, creates the shared caches and `PubDevClient`, and
   starts `PubMcpServer` over stdio.
2. `lib/src/server.dart` is the composition root. It registers all tools,
   resources, prompts, and resource-template completions, and wires the shared
   caches into the handlers.
3. `lib/src/data/pub_client.dart` is the transport boundary. It owns HTTP
   requests, retries, timeouts, concurrency limiting, JSON decoding,
   HTML-to-Markdown conversion, and package-tarball extraction.
4. `lib/src/tools/` contains the MCP tool handlers. These implement package
   search/detail/comparison, changelog lookup, dartdoc symbol lookup,
   source-file access, exact method-body extraction, and throw-statement
   extraction.
5. `lib/src/resources/` serves the `pub://meta/*` and `pub://package/{name}/*`
   resource namespaces.
6. `lib/src/prompts/prompts.dart` defines higher-level prompt workflows such as
   package setup, upgrade-impact analysis, and package-alternative evaluation.

## Main Data Sources

- pub.dev REST API endpoints for package metadata, scores, metrics, and search.
- dartdoc `index.json` files and symbol pages from package documentation.
- Rendered README, changelog, and example pages on pub.dev.
- Published `archive.tar.gz` package artifacts for raw source inspection.

## Direct Runtime Dependencies

| Package | Why it is direct | How pubdev_context uses it |
| --- | --- | --- |
| `analyzer` | The server needs structural Dart source inspection, not string matching. | `GetMethodBodyHandler` and `GetThrowStatementsHandler` call `parseString()` and walk AST nodes to return exact member bodies, locate `throw` expressions, and compute line-aware source snippets. |
| `archive` | pub.dev source inspection depends on decoding published tarballs. | `PubDevClient.getPackageSourceFiles()` downloads `archive.tar.gz`, inflates it with `GZipDecoder`, decodes it with `TarDecoder`, and builds the in-memory file map used by the source and AST tools. |
| `cli_config` | The executable needs a small typed config layer for flags plus environment-variable overrides. | `PubMcpConfig.fromArguments()` uses `Config` to merge `--log-level`, `--cache-dir`, and the `pubdev_context_*` environment variables into a typed server config. |
| `dart_mcp` | This is the MCP framework the package is built on. | The binary uses the stdio transport from `dart_mcp/stdio.dart`, `PubMcpServer` extends `MCPServer` plus the support mixins from `dart_mcp/server.dart`, and the example/tests use the MCP client types. |
| `html` | The server needs DOM-level section isolation before converting rendered pages to plain text. | `HtmlToMarkdown` uses `package:html` parsing to isolate the relevant `<main>` or class-based content block for README, example, and symbol-doc extraction before applying the package's Markdown conversion rules. |
| `http` | All remote data access goes through HTTP clients. | `PubDevClient` uses `http.Client` for pub.dev JSON, dartdoc, HTML, and tarball requests, while `MetaResourcesHandler` uses a dedicated `http.Client` to fetch the current stable Dart and Flutter SDK versions. |

## Direct Development Dependencies

| Package | Why it is direct | How pubdev_context uses it |
| --- | --- | --- |
| `build_runner` | Build-time generators in this workspace need an orchestrator. | The development install flow runs `dart run build_runner build --workspace`, and this package participates in that workspace build step. |
| `build_version` | The package exposes generated version metadata. | `bin/pubdev_context.dart` and `lib/src/server.dart` read the generated `packageVersion` constant from `lib/src/version.dart`; `build_version` is the build-time dependency that supports maintaining that generated file. |
| `coverage` | Maintainers collect package-level coverage reports. | Coverage is tooling-only here; it supports generating the coverage artifacts and reports and is not imported by the runtime library. |
| `mocktail` | Unit tests need deterministic mocks for network and handler boundaries. | The unit tests use `mocktail` to fake `http.Client` responses and validate retry, cache, parsing, and error-mapping behavior without live network calls. |
| `stream_channel` | In-process MCP testing needs a channel abstraction without spawning stdio binaries. | The example program and MCP protocol tests use `StreamChannel.withCloseGuarantee` to connect an in-process client and server. |
| `test` | The package uses Dart's standard test framework. | All unit and integration coverage in `test/unit/` and `test/integration/` is written with `package:test`. |
| `very_good_analysis` | The package opts into a stricter lint configuration. | `analysis_options.yaml` includes `../../analysis_options.yaml`, which in turn uses `very_good_analysis` for analyzer and lint rules. |

## Architectural Notes

- The server is intentionally cache-heavy. Search results feed resource
  completions, API indexes are shared between tools and resources, and parsed
  AST snapshots are shared between the two AST-based tools.
- `PubDevClient` is the only place that knows how to talk to pub.dev. Tool and
  resource handlers mostly validate inputs, consult caches, and shape MCP
  responses.
- Source inspection has two layers: raw file access from tarballs and
  AST-precise extraction via `analyzer` when an agent needs exact code slices.
- Prompt handlers do not make recommendations themselves. They provide guided
  workflows that tell an LLM which resources and tools to call next.