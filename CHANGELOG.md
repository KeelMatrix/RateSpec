# Changelog

Changes for `KeelMatrix.RateSpec` are recorded here.

## [Unreleased]

The first package release is planned and has not been published.

- Caller-token cancellation now wins over a terminal response, while non-token HTTP cancellation is reported as `HostFailure`; factory-thrown cancellation remains `Cancelled`.

## [0.1.0] - Planned

### Added

- Bounded sequential verification of ASP.NET Core initial bursts, rejection behavior, partition isolation, shared partitions, and unlimited endpoints.
- Predicate-based response and generic rejection-header expectations with cancellation and safety-ceiling enforcement.
