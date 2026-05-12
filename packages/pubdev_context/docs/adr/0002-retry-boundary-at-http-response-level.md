# Retry boundary sits at the HTTP response level, not the parsed-result level

`RetryPolicy.execute` wraps only `_getRaw` — the raw HTTP call that returns a `String`. JSON parsing happens after the retry loop returns, in the caller. This means `RetryPolicy` only ever sees `HttpStatusException` and never needs to reason about parse failures.

The alternative was to parse inside the `execute` lambda and signal parse failures via a thrown exception that the policy could catch. We rejected this because retry logic is a transport concern: a malformed response body will never succeed on retry, so it should not enter the retry loop at all. Keeping parsing outside `execute` also makes the boundary explicit and `RetryPolicy` easier to test in isolation.
