# Changelog

All notable changes to `dart_pubdev_mcp` are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.5.2]

### Added

- Self-update notice: the server checks pub.dev once per startup (rate-limited to ~24h across restarts) and, if a newer version exists, surfaces a `dartPubdevMcpUpdate` notice on the next tool-call response — at most once per session.
- `--no-update-check` flag / `dart_pubdev_mcp_UPDATE_CHECK` env var to disable it (default: on).

## [0.5.1]

### Fixed

- README.md

## [0.5.0]

### Changed

- **Breaking:** package renamed from `pubdev_context` to `dart_pubdev_mcp`. Version reset to `0.5.0` — not a continuation of the `0.4.0-rc.x` PoC line's numbering. Deliberately kept below `1.0.0`: the V1 tool surface is still considered pre-stable under semver, so the version number doesn't yet claim API stability.
