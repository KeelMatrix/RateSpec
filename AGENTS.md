# RateSpec Development Guide

## Navigation

- `src/KeelMatrix.RateSpec` contains the shipping public API and package metadata.
- `tests/KeelMatrix.RateSpec.Tests` contains in-memory ASP.NET Core behavior coverage.
- `smoke/RateSpec.ConsumerSmoke` validates the built package through `PackageReference`.
- `docs/behavior-guide.md` is the consumer behavior contract; `docs/DEV.md` is the local validation guide.
- `artifacts/` is disposable local package and build output and is ignored by Git.

## Invariants

- The shipping package targets `net8.0` only because it validates the current ASP.NET Core rate-limiting API surface.
- RateSpec is a bounded behavior verifier, not a limiter, load tester, retry helper, or distributed-coordination client.
- Verification is sequential by default, cancellation-aware, and never uses wall-clock sleeps for replenishment.
- Request factories own endpoint and partition details. Diagnostics and results never include request URLs, headers, partition values, response bodies, or raw exceptions.
- The package performs no hidden external HTTP call for verification. Telemetry is best effort and suppressed during local validation with `KEELMATRIX_NO_TELEMETRY=1`.
- The root `icon.png` is supplied separately. The conditional pack item may resolve it when present; do not create, copy, inspect, or modify icon bytes.

## Validation

Start with the matching test, then use the Release solution build/test, format verification, package inspection, vulnerability audit, and isolated package-consumer smoke described in `docs/DEV.md`. Do not modify unrelated repositories.
