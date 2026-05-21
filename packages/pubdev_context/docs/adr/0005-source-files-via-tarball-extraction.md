# Source file access uses pub.dev tarball extraction, not GitHub raw URLs or subprocess

`get_package_source_file` and `list_package_source_files` need the raw content of package source files. Three approaches were considered.

**Considered options:**

- **GitHub raw URL** _(rejected)_: construct a `raw.githubusercontent.com` URL from the `repository` field of `PackageDetail`. Zero new dependencies, fits the existing HTTP model. Rejected because `repository` is optional, non-GitHub repos are excluded, and the published version may not correspond cleanly to a git tag — making this unreliable for the packages where it matters most.
- **`dart pub unpack` subprocess** _(rejected)_: shell out to `dart pub unpack` to write files to a temp directory, then read and delete them. No new dependencies. Rejected because it introduces process-spawning and temp-directory lifecycle management — a first of its kind in this server — and is stateful in a way the pure HTTP+in-memory architecture is not.
- **pub.dev tarball via HTTP + `archive` package** _(chosen)_: `GET https://pub.dev/api/packages/{name}/versions/{version}/archive.tar.gz`, decompress in memory with the `archive` package, cache the full `Map<String, String>` under `source:<name>:<version>`. Works for every published package regardless of VCS host, is version-exact, stays in-process, and extends `PubDevClient` cleanly.

ADR-0003 rejected tarball extraction for the example resource as disproportionate cost for a single resource and left the door open: "if tarball extraction is added later as its own milestone, the example resource can be migrated then." This is that milestone.

**Consequences:** The `archive` package is added as a dependency. The full extracted file map is held in memory for the cache TTL (1 hour). For typical pub.dev packages this is small; unusually large packages are accepted as-is with no size cap at this stage.
