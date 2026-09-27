# KeelMatrix.RateSpec

`KeelMatrix.RateSpec` verifies the observable burst, rejection, and partition behavior of an ASP.NET Core rate-limited endpoint. It sends a small sequential request sequence through the caller's test-host `HttpClient`; it does not implement a limiter or run a load test.

## Install

```bash
dotnet add package KeelMatrix.RateSpec
```

## Quick Start

```csharp
var contract = new RateContract(
    client,
    RateScenario.InitialBurst(
        _ => new HttpRequestMessage(HttpMethod.Get, "/limited"),
        RateExpectation.Burst(5)));

var result = await new RateVerifier().VerifyAsync(contract, cancellationToken);
Assert.True(result.Succeeded, result.Message);
```

The request factory belongs to the application, so it can provide the headers or route data used by its partition policy. Verification is sequential by default, bounded, cancellable, and never retries automatically. Caller-token cancellation always returns `Cancelled`, even after a valid terminal response; a factory-thrown `OperationCanceledException` is also `Cancelled`, while an HTTP cancellation without caller-token cancellation is `HostFailure`. `RequestsIssued` counts only request messages returned by a factory and handed to `HttpClient`; factory failures before request creation are not counted. A verdict after at least one request, including a failed verdict or cancellation after a request, makes one best-effort coarse activation call; preflight or no-request verdicts do not. Telemetry failure never changes the result.

## Documentation

See the [RateSpec behavior guide](docs/behavior-guide.md) for partition isolation and sharing, unlimited endpoints, custom rejection metadata, cancellation, safety limits, privacy, and the v1 timing boundary. [Development validation](docs/DEV.md) covers building and package-consumer smoke testing.

RateSpec is designed for in-memory or test-host integration tests. Production base addresses and unbounded user-controlled partition cardinality are not v1 targets; the latter can itself exhaust resources. Use a load-testing tool for capacity or throughput questions.

## Supported Frameworks and Platforms

The package targets `net8.0` and is intended for .NET 8 integration-test projects using ASP.NET Core. Release CI validates
the library tests and formatting on Windows, Linux, and macOS; the package archive and isolated package-consumer gate
runs on Ubuntu. Earlier .NET versions are not supported.

## License

MIT. See [LICENSE](LICENSE).
