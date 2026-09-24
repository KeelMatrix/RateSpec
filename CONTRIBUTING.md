# Contributing

## Before you begin

Install the .NET 8 SDK and read the [behavior guide](docs/behavior-guide.md) and [development guide](docs/DEV.md). Keep changes inside the approved observable behavior boundary: RateSpec is not a limiter, load generator, or distributed coordination system.

## Making changes

Use focused tests for behavior changes. Public API additions belong in the shipping project's API baseline. Keep diagnostics content-free and do not add automatic retries or wall-clock replenishment waits.

## Validation

Run the Release build and test commands in [docs/DEV.md](docs/DEV.md), with `KEELMATRIX_NO_TELEMETRY=1`. For package changes, inspect the produced `.nupkg` and `.snupkg`, then run the isolated package-consumer smoke project.

Report security vulnerabilities using [SECURITY.md](SECURITY.md), not a public issue. Community standards are in [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

