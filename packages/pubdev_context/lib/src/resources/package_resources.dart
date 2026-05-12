/// Resource handlers for the pub://package/{name}/ namespace.
///
/// Serves two parameterised ResourceTemplates:
///   - pub://package/{name}/readme  — full README (text/markdown, 60 min TTL)
///   - pub://package/{name}/api     — dartdoc index.json symbols (60 min TTL)
///
/// CompletionsSupport autocomplete for {name} is wired here using
/// cached search results.
/// See issue #11.
library;

// TODO(#11): implement package resource handlers and CompletionsSupport
