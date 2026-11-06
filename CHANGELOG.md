# Changelog

Changes for `KeelMatrix.RateSpec` are recorded here.

## [Unreleased]

## [0.1.0] - 2026-11-06

### Added

- Verify ASP.NET Core initial bursts, rejection, partition isolation, shared partitions, and bounded sequences on unlimited endpoints through a test-host `HttpClient`.
- Define accepted and rejected response predicates, exact rejection statuses, and rejection-header expectations, with structured observations and failure verdicts.
- Run sequential, cancellable checks with request ceilings, no automatic retries, and no sleeps for window replenishment.
- Receive diagnostics without request URLs, header values, partition identities, response bodies, or raw exception details.
