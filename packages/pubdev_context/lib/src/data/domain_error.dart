/// Domain error types for pub.dev API failures.
///
/// All pub.dev client errors are represented as [DomainError] values wrapped
/// in [PubDevResult] — they are never thrown as Dart exceptions across module
/// boundaries. Callers pattern-match on [PubDevSuccess] vs [PubDevFailure] to
/// access the result or the structured error.
library;

import 'dart:convert';

/// Well-known error codes returned by the pub.dev API client.
abstract final class DomainErrors {
  /// The requested package was not found on pub.dev.
  static const packageNotFound = 'package_not_found';

  /// pub.dev rate-limited the request (HTTP 429).
  static const rateLimited = 'rate_limited';

  /// pub.dev was temporarily unavailable (HTTP 5xx).
  static const serviceUnavailable = 'service_unavailable';

  /// The response body could not be parsed.
  static const unexpectedResponse = 'unexpected_response';

  /// A request to pub.dev did not complete within the allotted time.
  static const requestTimeout = 'request_timeout';

  /// The package changelog contains no recognisable version headings.
  static const noDocumentation = 'no_documentation';

  /// A supplied parameter value is outside the accepted range or format.
  static const invalidInput = 'invalid_input';
}

/// A structured error value returned when a pub.dev API operation fails.
///
/// Serialises to `{ "error": ..., "message": ..., "suggestion": ..., "docs": ... }`.
/// Pass [docs] when a relevant pub.dev URL aids self-service recovery.
final class DomainError {
  /// Creates a [DomainError] with the required fields.
  const DomainError({
    required this.error,
    required this.message,
    required this.suggestion,
    this.docs,
  });

  /// A short machine-readable code identifying the failure category.
  final String error;

  /// A human-readable explanation of what went wrong.
  final String message;

  /// Actionable advice for the caller to resolve the issue.
  final String suggestion;

  /// An optional URL to relevant documentation.
  final String? docs;

  /// Returns this error as a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'error': error,
    'message': message,
    'suggestion': suggestion,
    if (docs != null) 'docs': docs,
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
