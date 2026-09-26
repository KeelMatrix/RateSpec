# RateSpec Behavior Guide

This guide defines the v1 consumer contract for `KeelMatrix.RateSpec`. RateSpec observes the HTTP behavior of the test host configured by the application; it does not own or emulate ASP.NET Core limiter algorithms.

## Installation and first success

Install the package in an integration-test project:

```bash
dotnet add package KeelMatrix.RateSpec
```

Create an `HttpClient` from the application's in-memory or test host, then declare an initial burst:

```csharp
var scenario = RateScenario.InitialBurst(
    requestNumber => new HttpRequestMessage(HttpMethod.Get, "/limited"),
    RateExpectation.Burst(5));

var result = await new RateVerifier().VerifyAsync(new RateContract(client, scenario));
```

The default accepted predicate is any 2xx response. The default rejection predicate is any non-2xx response, so the application remains free to configure its rejection status. With those defaults, a declared `rejectionStatusCode` must be outside 200-299; a 2xx rejection status contradicts the two default predicates and is rejected while the expectation is created. When either predicate is custom, the caller must ensure that the declared rejection status does not satisfy the accepted predicate and does satisfy the rejected predicate. Use `BurstWithSuccessStatusRange` or custom predicates when the endpoint has a more specific contract.

## Initial burst and rejection

`RateExpectation.Burst(n)` issues exactly `n` accepted-response checks followed by one rejection check. The verifier sends them sequentially and never retries. A request factory receives only its zero-based request number and is responsible for creating a fresh request message. Each factory sequence starts at zero; the second factory in a partition scenario also receives zero for its first request.

## Partition A/B isolation

The caller controls the partition inputs:

```csharp
var scenario = RateScenario.PartitionIsolation(
    _ => CreatePartitionedRequest("A"),
    _ => CreatePartitionedRequest("B"),
    RateExpectation.Burst(5));
```

RateSpec exhausts A, then checks that B can begin its own burst. It never interprets or prints the partition values. `SharedPartition` performs the inverse contract: after the first factory consumes its burst, the first request from the second factory must be rejected.

When two distinct ASP.NET Core policies can produce equal partition keys, test them as separate endpoint scenarios. Named policies are expected to keep their limiter state isolated. Inline policies should be tested separately with the same partition key and distinct limits, matching the collision shape documented in [ASP.NET Core issue #67326](https://github.com/dotnet/aspnetcore/issues/67326). This catches policy-selection and namespace mistakes without relying on configuration inspection.

## Unlimited endpoints

Use `RateExpectation.Unlimited(count)` with `RateScenario.Unlimited`. The verifier issues the requested bounded count and expects every response to satisfy the accepted predicate. This proves the selected endpoint remains available for the tested sequence; it is not a claim about unlimited capacity.

## Rejection status and headers

Use the optional `rejectionStatusCode` and `rejectedHeaderPredicates` arguments on `RateExpectation.Burst` for application-specific rejection behavior:

```csharp
RateExpectation.Burst(
    5,
    rejectionStatusCode: 429,
    rejectedHeaderPredicates: new Dictionary<string, Func<string?, bool>>
    {
        ["Retry-After"] = value => value is not null
    });
```

Header predicates are generic and run only on the expected rejection response. RateSpec does not promise a particular `Retry-After` value. Current runtime work continues to examine metadata semantics across algorithms, so timing metadata should be asserted only when the application contract deliberately requires it.

## Safety request ceiling

The default verifier ceiling is 100 requests per contract and the hard maximum is 1,000. `RateVerifier(maximumRequestCount: ...)` can impose a smaller ceiling. Counts that would exceed the selected ceiling fail before the first request is created. RateSpec is not a high-volume probe and does not accept an external URL convenience mode.

## Cancellation

Pass a `CancellationToken` to `VerifyAsync`. It is checked before each request and passed to `HttpClient.SendAsync`. Cancellation returns a `Cancelled` verdict and does not trigger a retry.

## Behavioral contract tests are not load tests

RateSpec answers a narrow regression question: does this configured endpoint accept, partition, and reject a small declared sequence? It does not measure requests per second, capacity, latency under load, DDoS resistance, or distributed coordination. Use a dedicated load/soak/stress tool for those questions.

## No timing promises in v1

RateSpec deliberately verifies initial capacity and rejection only. It does not sleep for a window to replenish and does not promise a deterministic virtual clock. ASP.NET Core's built-in limiters expose algorithm-specific replenishment behavior, and current runtime discussions continue to examine `Retry-After` semantics. A future timing feature requires a defensible deterministic runtime seam; ordinary wall-clock sleeps are not part of this API.

## Partition cardinality and network boundary

Microsoft warns that partitioning on unbounded user-controlled input can exhaust memory and become a denial-of-service concern. Keep application partition cardinality bounded and intentional; RateSpec does not sanitize or cap the application's partitioner.

The documented path is an in-memory or test-host `HttpClient`. The package makes no hidden network call for verification and does not provide a convenience API for probing arbitrary production addresses. After a verdict with at least one request issued, including a failed verdict or cancellation after a request, it makes one best-effort coarse activation call. Preflight or no-request verdicts make no activation call. Telemetry failure never changes a verdict; the privacy boundary and opt-out are documented in [Privacy](../PRIVACY.md).
