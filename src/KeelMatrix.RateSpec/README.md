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

The result is structured and does not retain response bodies, headers, or caller-supplied partition values. Requests are sequential, bounded, cancellable, and never retried. Use an in-memory/test host; arbitrary production base addresses are outside the v1 design target.

For the complete behavior contract, see the [RateSpec behavior guide](https://github.com/KeelMatrix/RateSpec/blob/main/docs/behavior-guide.md).

