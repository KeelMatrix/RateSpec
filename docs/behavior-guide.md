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

RateSpec targets `net8.0` and is intended for .NET 8 integration-test projects using ASP.NET Core. Release CI validates
the library tests, formatting, package archives, dependency audit, and isolated package-consumer gate on Windows, Linux,
and macOS. Earlier .NET versions are not supported.

The default accepted predicate is any 2xx response. The default rejection predicate is any non-2xx response, so the application remains free to configure its rejection status. With those defaults, a declared `rejectionStatusCode` must be outside 200-299; a 2xx rejection status contradicts the two default predicates and is rejected while the expectation is created. When either predicate is custom, the verifier still requires the observed rejection response to satisfy the rejected predicate and not satisfy the accepted predicate. A response matching both predicates therefore cannot produce a successful verdict. `BurstWithSuccessStatusRange` uses the default non-2xx rejection predicate, so it also rejects every exact 2xx rejection code during construction, even when the accepted range itself is outside 200-299.

## Initial burst and rejection

`RateExpectation.Burst(n)` issues exactly `n` accepted-response checks followed by one rejection check. The verifier sends them sequentially and never retries. A request factory receives only its zero-based request number and is responsible for creating a fresh request message. Each factory sequence starts at zero; the second factory in a partition scenario also receives zero for its first request. `RequestsIssued` counts only request messages returned by a factory and handed to `HttpClient`; a factory throw, null result, or cancellation before a request is created does not inflate the count.

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

Header predicates are generic and run only on the expected rejection response after the accepted/rejected response predicates have been checked. RateSpec does not promise a particular `Retry-After` value. Current runtime work continues to examine metadata semantics across algorithms, so timing metadata should be asserted only when the application contract deliberately requires it.

Both burst factories require nonempty ASCII HTTP field-name tokens as defined by [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html#name-field-names). Names are case-insensitive and must be unique even when duplicate predicates are identical. Invalid names and case-equivalent duplicates throw `ArgumentException` while the expectation is created, before any request factory or HTTP send. Constraints are copied into a read-only dictionary. Response and content headers are supported; absent headers pass `null` to the predicate and multiple values are joined with `, ` in their observed order.

## Failure classifications

An expected accepted response that fails the accepted predicate is `EarlyRejection` only if it matches the configured rejected predicate. An expected rejection that fails the rejected predicate is `MissingRejection` only if it matches the configured accepted predicate. A response matching neither is `StatusMismatch`. These rules use the application's predicates, including non-2xx acceptance and 2xx rejection.

The first response of partition B maps a proven `EarlyRejection` to `PartitionLeakage`. Later B responses retain the ordinary burst classifications. A shared partition's second factory maps a proven `MissingRejection` to `ExpectedSharingNotObserved`. Unlimited mode has only an accepted-response contract; any failed acceptance is `UnexpectedLimit`. An overlapping rejection/acceptance, or an exact rejection-status mismatch, is `StatusMismatch`; a failed header predicate is `HeaderMismatch`. Predicate exceptions produce a sanitized `HostFailure`, with caller cancellation taking precedence.

## Request and response cleanup

After every attempt, RateSpec attempts response disposal and then request disposal independently. Issuance and any observed status survive either cleanup failure. An already evaluated response retains its `PredicateMatched` value even when cleanup prevents a successful scenario. A cleanup failure is `HostFailure`, overriding a predicate mismatch or earlier host failure; caller-token cancellation overrides all of them and returns `Cancelled`, including cancellation during cleanup. Without a cleanup failure or caller cancellation, the original evaluation stands. A factory-thrown `OperationCanceledException` remains `Cancelled` unless cleanup itself fails. Cleanup and predicate exception details are never exposed, and failures never trigger retries.

## Safety request ceiling

The default verifier ceiling is 100 requests per contract and the hard maximum is 1,000. `RateVerifier(maximumRequestCount: ...)` can impose a smaller ceiling. Counts that would exceed the selected ceiling fail before the first request is created. RateSpec is not a high-volume probe and does not accept an external URL convenience mode.

## Cancellation

Pass a `CancellationToken` to `VerifyAsync`. The caller token is checked before each request and after each HTTP response and response predicate. If it is cancelled during verification, the public result is always `Cancelled`, including when a valid terminal response was already received; no retry is triggered. A request factory that directly throws `OperationCanceledException` also remains a `Cancelled` result. By contrast, an HTTP timeout or other `OperationCanceledException` from `HttpClient` whose token was not cancelled is a `HostFailure`, because `Cancelled` documents caller cancellation rather than host failure.

## Behavioral contract tests are not load tests

RateSpec answers a narrow regression question: does this configured endpoint accept, partition, and reject a small declared sequence? It does not measure requests per second, capacity, latency under load, DDoS resistance, or distributed coordination. Use a dedicated load/soak/stress tool for those questions.

## No timing promises in v1

RateSpec deliberately verifies initial capacity and rejection only. It does not sleep for a window to replenish and does not promise a deterministic virtual clock. ASP.NET Core's built-in limiters expose algorithm-specific replenishment behavior, and current runtime discussions continue to examine `Retry-After` semantics. A future timing feature requires a defensible deterministic runtime seam; ordinary wall-clock sleeps are not part of this API.

## Partition cardinality and network boundary

Microsoft warns that partitioning on unbounded user-controlled input can exhaust memory and become a denial-of-service concern. Keep application partition cardinality bounded and intentional; RateSpec does not sanitize or cap the application's partitioner.

The documented path is an in-memory or test-host `HttpClient`. The package makes no hidden network call for verification and does not provide a convenience API for probing arbitrary production addresses. After a verdict with at least one request issued, including a failed verdict or cancellation after a request, it makes one best-effort coarse activation call. Successful explicit verification also requests retention through the shared client's `TrackHeartbeat` API. Failed or cancelled results do not request retention; preflight or no-request results request neither event. There is no periodic timer. The shared client owns identity, state, weekly cadence, deduplication, opt-out, delivery and failure isolation; a new activation suppresses retention for that ISO week, and later successful explicit use can supply later-week retention. Telemetry failure never changes a verdict; the privacy boundary and opt-out are documented in [Privacy](../PRIVACY.md).
