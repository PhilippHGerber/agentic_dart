# SDK release notes retrieval via raw GitHub fetch and structured parsing

`dart-pubdev-explorer` gains access to Dart SDK and Flutter SDK/framework release notes and changelogs through a dedicated tool — `get_sdk_release_notes`. Release notes are acquired via lightweight raw GitHub requests with a 24-hour in-memory cache and local tarball fallback, parsed into structured category sections (`Language`, `Core libraries`, `Tools`, `Breaking changes`, etc.), and bounded with a token-efficient default `limit` (`1` for latest lookup, `5` for range diffs).

## Context

Neither the Dart SDK nor the Flutter SDK is published on pub.dev. LLM agents frequently need release notes during migrations, dependency updates, and bug investigations ("what changed between Dart 3.2.0 and 3.5.0?", "what is new in the latest Flutter release?").

SDK changelogs differ markedly from typical pub.dev package changelogs:
- **Length**: A single Dart SDK release (e.g. `3.13.0` or `3.0.0`) can span 150–350 lines with detailed explanations and code samples; returning 5 historical Dart versions at once can consume 3,500–6,000 tokens.
- **Section structure**: Both SDKs group changes into distinct functional areas (`Language`, `Core libraries`, `Tools`, `Breaking changes` in Dart; `Framework`, `Engine`, hotfixes in Flutter).

## Decision

**1. Tool Surface: Single Unified Tool (`get_sdk_release_notes`)**
- Dedicated tool mirroring the `sdk` selector pattern from ADR 0006 (`get_sdk_source_slice`, `list_sdk_source_files`, `grep_sdk_source`).
- Parameters:
  - `sdk` (`'dart' | 'flutter'`, required).
  - `version` (optional target version; when omitted, defaults to the newest upstream release in the changelog).
  - `fromVersion` (optional exclusive lower bound for upgrade diffs).
  - `limit` (optional maximum entries returned; default `1` when `fromVersion` is omitted, default `5` when `fromVersion` is supplied).

**2. Acquisition Strategy: Lightweight Raw GitHub Fetch with 24h In-Memory Cache and Tarball Fallback**
- Fetches `CHANGELOG.md` directly via raw GitHub endpoints:
  - Dart: `https://raw.githubusercontent.com/dart-lang/sdk/main/CHANGELOG.md`
  - Flutter: `https://raw.githubusercontent.com/flutter/flutter/master/CHANGELOG.md` (root `CHANGELOG.md` covering framework release milestones and hotfixes).
- Caching: In-memory `KeyedCache` with a 24-hour TTL.
- Fallback: If an SDK source tarball for the target SDK is already cached locally in `TarballDiskCache`, `CHANGELOG.md` is read directly from disk if raw network fetch is unavailable.
- *Rejected — Download-only via 35MB SDK Tarball*: Downloading full SDK source tarballs solely to read a 30–140KB changelog wastes bandwidth and adds multi-second latency for release note queries.
- *Rejected — Web Scraping / GitHub Releases API*: Scraping `dart.dev` / `docs.flutter.dev` or using rate-limited GitHub REST API is brittle compared to parsing the authoritative markdown sources in the git repositories.

**3. Version Anchoring and Token Economy**
- Omitting `version` anchors to the upstream latest release notes (top of `CHANGELOG.md`).
- Default `limit = 1` when `fromVersion` is omitted prevents prompt flooding on general point queries.
- Supplying `fromVersion` switches default `limit` to `5`, providing a bounded upgrade window.

**4. Structured Section Parsing**
- Response schema mirrors `get_changelog` while adding a categorized `sections` map:
  ```json
  {
    "resolvedVersion": "3.14.0",
    "entries": [
      {
        "version": "3.14.0",
        "date": "2025-01-15T00:00:00.000Z",
        "changes": ["..."],
        "sections": {
          "Libraries": ["dart:ffi: Added NativeFinalizer.callback..."],
          "Tools": ["Formatter: Don't crash..."]
        },
        "breaking": false
      }
    ]
  }
  ```
- Subheadings in markdown are parsed into the `sections` map (`Map<String, List<String>>`) and aggregated into the flat `changes` list.
- `breaking: true` is computed if a `Breaking changes` section or explicit breaking notation is detected.

**5. Error Handling**
- `SDK_VERSION_NOT_FOUND`: Returned when the requested `version` or `fromVersion` does not exist in the changelog.
- `INVALID_ARGUMENT`: Returned when `sdk` is unrecognized or input bounds are invalid (e.g. `fromVersion` is newer than `version`).
- `SERVICE_UNAVAILABLE` / `REQUEST_TIMEOUT`: Returned on network failures when no cached changelog exists.

## Consequences

- Adds `get_sdk_release_notes` tool definition and handler.
- Adds SDK changelog caching infrastructure to `CacheRegistry` (24h TTL).
- Keeps `get_changelog` focused strictly on pub.dev packages while providing full feature parity for Dart and Flutter SDKs under the `get_sdk_*` tool family.
