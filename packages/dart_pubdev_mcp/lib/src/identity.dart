/// The MCP Server Identity (see `CONTEXT.md`): the name this server presents
/// to MCP clients — the handshake `Implementation.name`, the `.mcp.json`
/// server key, and the CLI executable a user types. Distinct from the
/// Package Identifier (`dart_pubdev_mcp`), which is constrained to
/// `lowercase_with_underscores`; this one allows hyphens.
///
/// [kMcpServerIdentity] and [kMcpServerTitle] are distinct on purpose: the
/// identity is a stable, programmatic name (also used for logical matching
/// and configuration keys), while the title is the human-readable label MCP
/// clients render in their UI. Changing the title must never be treated as
/// changing the server's identity.
const kMcpServerIdentity = 'dart-pubdev-explorer';

/// The human-readable display title for this server, sent as the handshake
/// `Implementation.title`. See [kMcpServerIdentity] for how this differs
/// from the identity `name`.
const kMcpServerTitle = 'Dart pub.dev Explorer';
