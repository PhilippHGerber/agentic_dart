/// The MCP Server Identity (see `CONTEXT.md`): the name this server presents
/// to MCP clients — the handshake `Implementation.name`, the `.mcp.json`
/// server key, and the CLI executable a user types. Distinct from the
/// Package Identifier (`dart_pubdev_mcp`), which is constrained to
/// `lowercase_with_underscores`; this one allows hyphens.
const kMcpServerIdentity = 'dart-pubdev-explorer';
