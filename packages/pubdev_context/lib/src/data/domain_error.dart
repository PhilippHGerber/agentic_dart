/// Domain error types for pub.dev API failures.
///
/// All pub.dev client errors are represented as [DomainError] values wrapped
/// in [PubDevResult] — they are never thrown as Dart exceptions across module
/// boundaries. Callers pattern-match on [PubDevSuccess] vs [PubDevFailure] to
/// access the result or the structured error.
library;

import 'dart:convert';

/// Well-known error codes returned by the pub.dev API client.
///
/// All values are `SCREAMING_SNAKE_CASE` as required by ADR 0002.
abstract final class DomainErrors {
  /// The requested package was not found on pub.dev.
  static const packageNotFound = 'PACKAGE_NOT_FOUND';

  /// pub.dev rate-limited the request (HTTP 429). Retryable.
  static const rateLimited = 'RATE_LIMITED';

  /// pub.dev was temporarily unavailable (HTTP 5xx). Retryable.
  static const serviceUnavailable = 'SERVICE_UNAVAILABLE';

  /// The response body could not be parsed.
  static const unexpectedResponse = 'UNEXPECTED_RESPONSE';

  /// A request to pub.dev did not complete within the allotted time. Retryable.
  static const requestTimeout = 'REQUEST_TIMEOUT';

  /// The package changelog contains no recognisable version headings.
  static const noDocumentation = 'NO_DOCUMENTATION';

  /// A supplied parameter value is outside the accepted range or format.
  static const invalidArgument = 'INVALID_ARGUMENT';

  /// The requested symbol was not found (covers classes, methods, constructors,
  /// accessors, and top-level functions).
  static const symbolNotFound = 'SYMBOL_NOT_FOUND';

  /// The requested package example page was not found or is empty.
  static const exampleNotFound = 'EXAMPLE_NOT_FOUND';

  /// The requested source file was not found in the package tarball.
  static const sourceFileNotFound = 'SOURCE_FILE_NOT_FOUND';

  /// The supplied symbol name matches more than one entry and could not be
  /// resolved unambiguously.
  static const ambiguousSymbol = 'AMBIGUOUS_SYMBOL';

  /// The query or type filter yields zero matching symbols.
  static const noResults = 'NO_RESULTS';

  /// Dartdoc documentation was not found for one or both requested versions.
  /// No handler yet — registered for future use by `get_api_diff` (S9).
  static const documentationNotFound = 'DOCUMENTATION_NOT_FOUND';

  /// A package tarball download exceeded the per-tarball size limit.
  /// No handler yet — registered for future use by the tarball disk cache (S4).
  static const packageTooLarge = 'PACKAGE_TOO_LARGE';

  /// Codes for which [DomainError.retryable] is `true`.
  static const Set<String> _retryable = {rateLimited, serviceUnavailable, requestTimeout};
}

/// A structured error value returned when a pub.dev API operation fails.
///
/// Serialises to the ADR 0002 nested schema:
/// ```json
/// { "error": { "code": "…", "message": "…", "retryable": bool,
///              "suggestion": "…", "suggestedNextStep": {…}, "details": {…} } }
/// ```
/// [suggestedNextStep] and [details] are optional and omitted when `null`.
///
/// Pass [details] to carry error-specific structured data (e.g.
/// `{'candidates': [...]}` for [DomainErrors.ambiguousSymbol]).
/// Pass [suggestedNextStep] to provide a ready-to-fire tool call hint to the
/// LLM (e.g. `{'tool': 'find_symbols', 'arguments': {...}}`).
final class DomainError {
  /// Creates a [DomainError] with the required fields.
  const DomainError({
    required this.code,
    required this.message,
    required this.suggestion,
    this.suggestedNextStep,
    this.details,
  });

  /// A `SCREAMING_SNAKE_CASE` code identifying the failure category.
  final String code;

  /// A human-readable explanation of what went wrong.
  final String message;

  /// Actionable advice for the caller to resolve the issue.
  final String suggestion;

  /// An optional ready-to-fire tool call hint for the LLM.
  ///
  /// Shape: `{ "tool": "<name>", "arguments": { … } }`.
  final Map<String, Object?>? suggestedNextStep;

  /// Optional error-specific structured data (e.g. `candidates` list for
  /// [DomainErrors.ambiguousSymbol]).
  final Map<String, Object?>? details;

  /// Whether the operation that produced this error can usefully be retried.
  ///
  /// `true` for [DomainErrors.rateLimited], [DomainErrors.serviceUnavailable],
  /// and [DomainErrors.requestTimeout]; `false` for all others.
  bool get retryable => DomainErrors._retryable.contains(code);

  /// Returns this error as a JSON-encodable map in the ADR 0002 nested shape.
  Map<String, Object?> toJson() => {
    'error': {
      'code': code,
      'message': message,
      'retryable': retryable,
      'suggestion': suggestion,
      if (suggestedNextStep != null) 'suggestedNextStep': suggestedNextStep,
      if (details != null) 'details': details,
    },
  };

  /// Returns this error encoded as a JSON string.
  String toJsonString() => jsonEncode(toJson());
}

/// The result of a pub.dev client operation — either a success or a failure.
///
/// Pattern-match against [PubDevSuccess] and [PubDevFailure] to handle both
/// cases. Never catch exceptions instead of checking this type.
sealed class PubDevResult<T> {
  const PubDevResult();
}

/// A successful [PubDevResult] carrying a typed value.
final class PubDevSuccess<T> extends PubDevResult<T> {
  /// Creates a successful result with [value].
  const PubDevSuccess(this.value);

  /// The successful value returned by the operation.
  final T value;
}

/// A failed [PubDevResult] carrying a structured [DomainError].
final class PubDevFailure<T> extends PubDevResult<T> {
  /// Creates a failure result with [error].
  const PubDevFailure(this.error);

  /// The structured error describing what went wrong.
  final DomainError error;
}
