# Privacy

`KeelMatrix.RateSpec` does not send endpoint paths, base URLs, request headers, partition keys, tenant or user identifiers, API keys, tokens, IP addresses, response bodies, or raw exceptions as part of verification results or diagnostics.

After a verification reaches a verdict with at least one request issued, including a failed verdict or cancellation after a request, the package requests activation through [`KeelMatrix.Telemetry`](https://github.com/KeelMatrix/Telemetry). Successful explicit verification also requests a retention heartbeat; failed or cancelled verification does not. Preflight validation, safety-ceiling failures and no-request verdicts request neither. No periodic timer is started. The [behavior guide](docs/behavior-guide.md#partition-cardinality-and-network-boundary) defines this eligibility contract.

The shared component supplies tool/version and runtime information and its pseudonymous project identity. It owns local identity/marker/queue state, opt-out, delivery, weekly cadence, deduplication and failure isolation. Activation is recorded once per project; a new activation suppresses the heartbeat in that ISO week, and later successful explicit use can request a later-week heartbeat. Calls are best effort and never throw, so telemetry failure cannot alter verification results. See the shared component's [privacy contract](https://github.com/KeelMatrix/Telemetry/blob/main/PRIVACY.md) for its payload, local state and network behavior.

Set `KEELMATRIX_NO_TELEMETRY=1` for local development and CI. The repository's tests and smoke validation use this setting. The package performs no hidden network call for the HTTP verification itself.
