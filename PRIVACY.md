# Privacy

`KeelMatrix.RateSpec` does not send endpoint paths, base URLs, request headers, partition keys, tenant or user identifiers, API keys, tokens, IP addresses, response bodies, or raw exceptions as part of verification results or diagnostics.

After a verification reaches a verdict with at least one request issued, including a failed verdict or cancellation after a request, the package makes one best-effort activation call through [`KeelMatrix.Telemetry`](https://github.com/KeelMatrix/Telemetry). A preflight validation or safety-ceiling verdict, or cancellation before the first request is issued, makes no activation call. That shared component owns its documented opt-out, project-identity, and delivery behavior. Telemetry is coarse and optional; failures are swallowed and never alter the verification result.

Set `KEELMATRIX_NO_TELEMETRY=1` for local development and CI. The repository's tests and smoke validation use this setting. The package performs no hidden network call for the HTTP verification itself.
