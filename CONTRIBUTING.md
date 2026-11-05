# Contributing

## Before you begin

Install PowerShell 7 and the .NET 8 SDK, then read the [behavior guide](docs/behavior-guide.md) and [development guide](docs/DEV.md). Keep changes inside the approved observable behavior boundary: RateSpec is not a limiter, load generator, or distributed coordination system.

## Making changes

Use focused tests for behavior changes. Public API additions belong in the shipping project's API baseline. Keep diagnostics content-free and do not add automatic retries or wall-clock replenishment waits.

## Validation

Run `pwsh -NoProfile -File ./scripts/Validate-Local.ps1` from the repository root. It disables telemetry and checks the Release build/tests, formatting, repository guards, both package archives, direct/transitive vulnerabilities and an isolated exact-package consumer. See [docs/DEV.md](docs/DEV.md) for prerequisites and focused phases.

Report security vulnerabilities using [SECURITY.md](SECURITY.md), not a public issue. Community standards are in [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

