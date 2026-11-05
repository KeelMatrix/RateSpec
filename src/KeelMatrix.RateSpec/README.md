# KeelMatrix.RateSpec

`KeelMatrix.RateSpec` is the package for deterministic ASP.NET Core rate-limit behavior checks. It verifies an initial accepted burst, the following rejection, and partition behavior using the `HttpClient` supplied by the consumer's integration-test host.

## Install

```bash
dotnet add package KeelMatrix.RateSpec
```

## Quick Start

```csharp
var result = await new RateVerifier().VerifyAsync(
    new RateContract(
        client,
        RateScenario.InitialBurst(
            _ => new HttpRequestMessage(HttpMethod.Get, "/limited"),
            RateExpectation.Burst(5))));
```

The result is structured and does not retain response bodies, headers, or caller-supplied partition values. Requests are sequential, bounded, cancellable, and never retried. Caller-token cancellation always returns `Cancelled`, even after a valid terminal response; a factory-thrown `OperationCanceledException` is also `Cancelled`, while an HTTP cancellation without caller-token cancellation is `HostFailure`. `RequestsIssued` counts only request messages returned by a factory and handed to `HttpClient`; factory failures before request creation are not counted. A verdict after at least one request, including a failed verdict or cancellation after a request, makes one best-effort coarse activation call; preflight or no-request verdicts do not. Successful explicit verification also requests shared weekly retention; failed, cancelled, preflight and no-request results do not. There is no periodic timer. The shared client owns cadence, deduplication, suppression and failure isolation. Issued counts and received statuses survive request/response cleanup failures, which return `HostFailure` unless the caller token is cancelled. Header names must be valid HTTP tokens and unique ignoring case, or expectation construction fails before traffic. Use an in-memory/test host; arbitrary production base addresses are outside the v1 design target.

For the complete behavior contract, see the [RateSpec behavior guide](https://github.com/KeelMatrix/RateSpec/blob/main/docs/behavior-guide.md).
