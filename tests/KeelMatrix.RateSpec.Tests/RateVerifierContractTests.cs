using System.Net;
using Xunit;

namespace KeelMatrix.RateSpec.Tests;

public sealed class RateVerifierContractTests
{
    private static readonly string[] ResponseValues = ["one", "two"];
    private static readonly string[] ContentValues = ["en", "fr"];
    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    public async Task Header_declarations_are_validated_before_any_traffic(int factory)
    {
        var sends = 0;
        var factories = 0;
        using var client = new HttpClient(new DelegateHandler(_ =>
        {
            sends++;
            return new HttpResponseMessage(HttpStatusCode.TooManyRequests);
        }));
        foreach (var name in new[] { "", " ", "Retry After", "Retry-After:", "X\tName", "X\r\nName", "X/Name", "X(Name)", "Xé", "X\u007f", "X\0" })
        {
            Assert.Throws<ArgumentException>(() => CreateExpectation(factory, new Dictionary<string, Func<string?, bool>> { [name] = value => value is null }));
        }

        foreach (var reverse in new[] { false, true })
        {
            foreach (var redundant in new[] { false, true })
            {
                var entries = new[] { "Retry-After", "retry-after" };
                if (reverse) { Array.Reverse(entries); }
                var headers = new Dictionary<string, Func<string?, bool>>
                {
                    [entries[0]] = value => value == "120",
                    [entries[1]] = value => value == (redundant ? "120" : "60")
                };
                // This sequence previously passed when normalization retained only the 60 constraint.
                await Assert.ThrowsAsync<ArgumentException>(async () =>
                    await new RateVerifier().VerifyAsync(new RateContract(client,
                        RateScenario.InitialBurst(_ =>
                        {
                            factories++;
                            return Request();
                        }, CreateExpectation(factory, headers)))));
            }
        }

        Assert.Equal(0, factories);
        Assert.Equal(0, sends);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    public async Task Valid_header_contracts_cover_response_content_absence_and_multiple_values(int factory)
    {
        var calls = 0;
        using var client = new HttpClient(new DelegateHandler(_ =>
        {
            var response = new HttpResponseMessage(calls++ == 0 ? HttpStatusCode.OK : HttpStatusCode.TooManyRequests);
            response.Headers.TryAddWithoutValidation("X-Values", ResponseValues);
            response.Content = new StringContent("");
            response.Content.Headers.TryAddWithoutValidation("Content-Language", ContentValues);
            return response;
        }));
        var headers = new Dictionary<string, Func<string?, bool>>
        {
            ["x-values"] = value => value == "one, two",
            ["content-language"] = value => value == "en, fr",
            ["!#$%&'*+-.^_`|~012Az"] = value => value is null
        };
        var result = await new RateVerifier().VerifyAsync(new RateContract(client,
            RateScenario.InitialBurst(_ => Request(), CreateExpectation(factory, headers))));
        Assert.True(result.Succeeded, result.Message);
        Assert.Equal(2, calls);
    }

    public static IEnumerable<object[]> CleanupCases()
    {
        foreach (var shape in new[] { "burst", "isolation", "shared", "unlimited" })
        {
            var count = shape switch { "isolation" => 6, "shared" => 4, _ => 3 };
            for (var index = 0; index < count; index++)
            {
                foreach (var side in new[] { "request", "response", "both" })
                {
                    foreach (var outcome in new[] { "match", "mismatch", "throw", "cancel", "cleanup-cancel", "cleanup-oce" })
                    {
                        yield return new object[] { shape, index, side, outcome };
                    }

                    if (shape != "unlimited" && (index == 2 || (shape == "isolation" && index == 5) || (shape == "shared" && index == 3)))
                    {
                        foreach (var outcome in new[] { "header-mismatch", "header-throw", "header-cancel", "exact-mismatch" })
                        {
                            yield return new object[] { shape, index, side, outcome };
                        }
                    }
                }
            }
        }
    }

    [Theory]
    [MemberData(nameof(CleanupCases))]
    public async Task Cleanup_cannot_erase_issued_traffic_or_observed_status(string shape, int faultAt, string side, string outcome)
    {
        using var cancellation = new CancellationTokenSource();
        var sends = 0;
        var requestCleanups = 0;
        var responseCleanups = 0;
        var activation = 0;
        var retention = 0;
        var observedStatuses = new List<int>();
        void Cleanup(bool request, int index)
        {
            if (request) { requestCleanups++; } else { responseCleanups++; }
            if (index != faultAt) { return; }
            if (outcome == "cleanup-cancel") { cancellation.Cancel(); }
            if (side == "both" || side == (request ? "request" : "response"))
            {
                if (outcome == "cleanup-oce") { throw new OperationCanceledException("private-cleanup-detail"); }
                throw new InvalidOperationException("private-cleanup-detail");
            }
        }

        bool Predicate(HttpResponseMessage response, bool rejected)
        {
            if (sends - 1 == faultAt)
            {
                if (outcome == "cancel") { cancellation.Cancel(); }
                if (outcome == "throw") { throw new InvalidOperationException("private-predicate-detail"); }
                if (outcome == "mismatch") { return false; }
            }

            return (response.StatusCode is HttpStatusCode.TooManyRequests or HttpStatusCode.Forbidden) == rejected;
        }

        using var client = new HttpClient(new DelegateHandler(_ =>
        {
            var index = sends++;
            var status = shape != "unlimited" && (index == 2 || (shape == "isolation" && index == 5) || (shape == "shared" && index == 3))
                ? HttpStatusCode.TooManyRequests : HttpStatusCode.OK;
            if (status == HttpStatusCode.TooManyRequests && outcome == "exact-mismatch" && index != faultAt) { status = HttpStatusCode.Forbidden; }
            observedStatuses.Add((int)status);
            return new HttpResponseMessage(status) { Content = new CleanupContent(() => Cleanup(false, index)) };
        }));
        var created = 0;
        RateRequestFactory factory = _ =>
        {
            var index = created++;
            return new HttpRequestMessage(HttpMethod.Get, "http://local.test/") { Content = new CleanupContent(() => Cleanup(true, index)) };
        };
        var expectation = shape == "unlimited"
            ? RateExpectation.Unlimited(3, response => Predicate(response, false))
            : RateExpectation.Burst(2, response => Predicate(response, false), response => Predicate(response, true),
                rejectionStatusCode: outcome == "exact-mismatch" ? 403 : null,
                rejectedHeaderPredicates: new Dictionary<string, Func<string?, bool>>
                {
                    ["X-Contract"] = _ =>
                    {
                        if (sends - 1 != faultAt) { return true; }
                        if (outcome == "header-cancel") { cancellation.Cancel(); }
                        if (outcome == "header-throw") { throw new InvalidOperationException("private-header-detail"); }
                        return outcome != "header-mismatch";
                    }
                });
        var result = await new RateVerifier(100, () => activation++, () => retention++).VerifyAsync(
            new RateContract(client, Scenario(shape, factory, expectation)), cancellation.Token);

        Assert.Equal(outcome is "cancel" or "cleanup-cancel" or "header-cancel" ? RateVerificationFailureKind.Cancelled : RateVerificationFailureKind.HostFailure, result.FailureKind);
        Assert.Equal(faultAt + 1, sends);
        Assert.Equal(sends, created);
        Assert.Equal(sends, result.RequestsIssued);
        Assert.Equal(sends, requestCleanups);
        Assert.Equal(sends, responseCleanups);
        Assert.Equal(observedStatuses.Select(value => (int?)value), result.Scenarios.Single().Observations.Select(observation => observation.StatusCode));
        Assert.Equal(1, activation);
        Assert.Equal(0, retention);
        Assert.Equal(outcome is "match" or "cleanup-cancel" or "cleanup-oce", result.Scenarios.Single().Observations[^1].PredicateMatched);
        Assert.DoesNotContain("private", result.Message, StringComparison.Ordinal);
        Assert.DoesNotContain("private", result.Scenarios.Single().Message, StringComparison.Ordinal);
    }

    public static IEnumerable<object[]> ClassificationCases()
    {
        yield return Case("burst", 202, 204, RateVerificationFailureKind.EarlyRejection, 204);
        yield return Case("burst", 302, 429, RateVerificationFailureKind.MissingRejection, 302, 302);
        yield return Case("burst", 202, 204, RateVerificationFailureKind.StatusMismatch, 500);
        yield return Case("burst", 202, 204, RateVerificationFailureKind.StatusMismatch, 202, 500);
        yield return Case("isolation", 202, 204, RateVerificationFailureKind.EarlyRejection, 204);
        yield return Case("isolation", 202, 204, RateVerificationFailureKind.MissingRejection, 202, 202);
        yield return Case("isolation", 202, 204, RateVerificationFailureKind.PartitionLeakage, 202, 204, 204);
        yield return Case("isolation", 200, 429, RateVerificationFailureKind.StatusMismatch, 200, 429, 500);
        yield return Case("isolation", 302, 429, RateVerificationFailureKind.MissingRejection, 302, 429, 302, 302);
        yield return Case("isolation", 302, 429, RateVerificationFailureKind.StatusMismatch, 302, 429, 302, 500);
        yield return Case("shared", 302, 429, RateVerificationFailureKind.ExpectedSharingNotObserved, 302, 429, 302);
        yield return Case("shared", 202, 204, RateVerificationFailureKind.StatusMismatch, 202, 204, 500);
        yield return Case("unlimited", 302, 429, RateVerificationFailureKind.UnexpectedLimit, 500);
        yield return Case("unlimited", 202, 204, RateVerificationFailureKind.UnexpectedLimit, 204);
        yield return Case("unlimited", 302, 429, RateVerificationFailureKind.UnexpectedLimit, 200);
        yield return Case("burst", 202, 204, RateVerificationFailureKind.MissingRejection, 202, 202);
        yield return Case("isolation", 202, 204, RateVerificationFailureKind.StatusMismatch, 500);
        yield return Case("isolation", 202, 204, RateVerificationFailureKind.StatusMismatch, 202, 500);
        yield return Case("isolation", 302, 429, RateVerificationFailureKind.PartitionLeakage, 302, 429, 429);
        yield return Case("shared", 202, 204, RateVerificationFailureKind.ExpectedSharingNotObserved, 202, 204, 202);
        yield return Case("shared", 202, 204, RateVerificationFailureKind.EarlyRejection, 204);
        yield return Case("shared", 302, 429, RateVerificationFailureKind.MissingRejection, 302, 302);
        yield return Case("burst", 202, 204, RateVerificationFailureKind.None, 202, 204);
        yield return Case("isolation", 302, 429, RateVerificationFailureKind.None, 302, 429, 302, 429);
        yield return Case("shared", 202, 204, RateVerificationFailureKind.None, 202, 204, 204);
        yield return Case("unlimited", 302, 429, RateVerificationFailureKind.None, 302);
    }

    [Theory]
    [MemberData(nameof(ClassificationCases))]
    public async Task Classifications_follow_configured_predicates(string shape, int accepted, int rejected, int[] statuses, RateVerificationFailureKind expected)
    {
        var sends = 0;
        using var client = new HttpClient(new DelegateHandler(_ => new HttpResponseMessage((HttpStatusCode)statuses[sends++])));
        var expectation = shape == "unlimited"
            ? RateExpectation.Unlimited(1, response => (int)response.StatusCode == accepted)
            : RateExpectation.Burst(1, response => (int)response.StatusCode == accepted, response => (int)response.StatusCode == rejected);
        var result = await new RateVerifier().VerifyAsync(new RateContract(client, Scenario(shape, _ => Request(), expectation)));
        Assert.Equal(expected, result.FailureKind);
        Assert.Equal(statuses.Length, result.RequestsIssued);
        Assert.Equal(statuses.Length, sends);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Opposite_predicate_exceptions_are_sanitized_and_caller_cancellation_wins(bool cancel)
    {
        using var cancellation = new CancellationTokenSource();
        using var client = new HttpClient(new DelegateHandler(_ => new HttpResponseMessage(HttpStatusCode.NoContent)));
        var expectation = RateExpectation.Burst(1, _ => false, _ =>
        {
            if (cancel) { cancellation.Cancel(); }
            throw new InvalidOperationException("private-predicate-detail");
        });
        var result = await new RateVerifier().VerifyAsync(new RateContract(client,
            RateScenario.InitialBurst(_ => Request(), expectation)), cancellation.Token);
        Assert.Equal(cancel ? RateVerificationFailureKind.Cancelled : RateVerificationFailureKind.HostFailure, result.FailureKind);
        Assert.Equal(204, result.Scenarios.Single().Observations.Single().StatusCode);
        Assert.DoesNotContain("private", result.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Every_successful_explicit_execution_requests_shared_retention()
    {
        var activation = 0;
        var retention = 0;
        var verifier = new RateVerifier(100, () => activation++, () => retention++);
        using var client = new HttpClient(new DelegateHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)));
        var contract = new RateContract(client, RateScenario.Unlimited(_ => Request(), RateExpectation.Unlimited(1)));
        // First, repeated, and later-week executions have identical adapter eligibility.
        // The shared client alone decides the current week and deduplicates delivery.
        for (var execution = 0; execution < 3; execution++)
        {
            Assert.True((await verifier.VerifyAsync(contract)).Succeeded);
            Assert.Equal(execution + 1, activation);
            Assert.Equal(execution + 1, retention);
        }
    }

    [Theory]
    [InlineData("status", RateVerificationFailureKind.StatusMismatch)]
    [InlineData("header", RateVerificationFailureKind.HeaderMismatch)]
    [InlineData("header-throw", RateVerificationFailureKind.HostFailure)]
    [InlineData("header-cancel", RateVerificationFailureKind.Cancelled)]
    [InlineData("accepted-throw", RateVerificationFailureKind.HostFailure)]
    [InlineData("rejected-throw", RateVerificationFailureKind.HostFailure)]
    [InlineData("opposite-accepted-throw", RateVerificationFailureKind.HostFailure)]
    [InlineData("opposite-rejected-throw", RateVerificationFailureKind.HostFailure)]
    public async Task Exact_status_headers_and_predicate_failures_have_public_classifications(string outcome, RateVerificationFailureKind expected)
    {
        using var cancellation = new CancellationTokenSource();
        var sends = 0;
        using var client = new HttpClient(new DelegateHandler(_ =>
        {
            sends++;
            var status = sends == 1 ? HttpStatusCode.Found : HttpStatusCode.NoContent;
            if ((outcome == "opposite-accepted-throw" && sends == 2) || outcome == "opposite-rejected-throw") { status = HttpStatusCode.InternalServerError; }
            return new HttpResponseMessage(status);
        }));
        var expectation = RateExpectation.Burst(1, response =>
        {
            if (outcome == "accepted-throw" || (outcome == "opposite-accepted-throw" && sends == 2)) { throw new InvalidOperationException("private-accepted-detail"); }
            return response.StatusCode == HttpStatusCode.Found;
        }, response =>
        {
            if (outcome is "rejected-throw" or "opposite-rejected-throw") { throw new InvalidOperationException("private-rejected-detail"); }
            return response.StatusCode == HttpStatusCode.NoContent;
        }, rejectionStatusCode: outcome == "status" ? 429 : 204,
        rejectedHeaderPredicates: new Dictionary<string, Func<string?, bool>>
        {
            ["X-Contract"] = _ =>
            {
                if (outcome == "header-throw") { throw new InvalidOperationException("private-header-detail"); }
                if (outcome == "header-cancel") { cancellation.Cancel(); }
                return outcome != "header";
            }
        });
        var result = await new RateVerifier().VerifyAsync(new RateContract(client, RateScenario.InitialBurst(_ => Request(), expectation)), cancellation.Token);
        Assert.Equal(expected, result.FailureKind);
        Assert.Equal(sends, result.RequestsIssued);
        Assert.NotNull(result.Scenarios.Single().Observations[^1].StatusCode);
        Assert.DoesNotContain("private", result.Message, StringComparison.Ordinal);
    }

    public static IEnumerable<object[]> HostCleanupCases()
    {
        foreach (var shape in new[] { "burst", "isolation", "shared", "unlimited" })
        {
            var count = shape switch { "isolation" => 4, "shared" => 3, _ => 2 };
            for (var faultAt = 0; faultAt < count; faultAt++)
            {
                foreach (var outcome in new[] { "fault", "host-cancel", "caller-cancel" })
                {
                    yield return new object[] { shape, faultAt, outcome };
                }
            }
        }
    }

    [Theory]
    [MemberData(nameof(HostCleanupCases))]
    public async Task Host_failure_and_request_cleanup_preserve_handoff_without_inventing_a_status(string shape, int faultAt, string outcome)
    {
        using var cancellation = new CancellationTokenSource();
        var sends = 0;
        var requestCleanups = 0;
        var responseCleanups = 0;
        using var client = new HttpClient(new DelegateHandler(_ =>
        {
            var index = sends++;
            if (index == faultAt)
            {
                if (outcome == "caller-cancel") { cancellation.Cancel(); }
                if (outcome != "fault") { throw new OperationCanceledException("private-host-detail"); }
                throw new InvalidOperationException("private-host-detail");
            }
            var status = shape != "unlimited" && (index == 1 || index == 3) ? HttpStatusCode.TooManyRequests : HttpStatusCode.OK;
            return new HttpResponseMessage(status) { Content = new CleanupContent(() => responseCleanups++) };
        }));
        var expectation = shape == "unlimited" ? RateExpectation.Unlimited(2) : RateExpectation.Burst(1);
        var result = await new RateVerifier().VerifyAsync(new RateContract(client, Scenario(shape, _ =>
            new HttpRequestMessage(HttpMethod.Get, "http://local.test/")
            {
                Content = new CleanupContent(() =>
                {
                    if (requestCleanups++ == faultAt) { throw new InvalidOperationException("private-cleanup-detail"); }
                })
            }, expectation)), cancellation.Token);
        Assert.Equal(outcome == "caller-cancel" ? RateVerificationFailureKind.Cancelled : RateVerificationFailureKind.HostFailure, result.FailureKind);
        Assert.Equal(faultAt + 1, sends);
        Assert.Equal(sends, result.RequestsIssued);
        Assert.Equal(sends, requestCleanups);
        Assert.Equal(sends - 1, responseCleanups);
        Assert.Null(result.Scenarios.Single().Observations[^1].StatusCode);
        Assert.DoesNotContain("private", result.Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("safety", 0, 0)]
    [InlineData("factory", 0, 0)]
    [InlineData("factory-cancel", 0, 0)]
    [InlineData("cancel-before", 0, 0)]
    [InlineData("cancel-after", 1, 0)]
    [InlineData("host", 1, 0)]
    [InlineData("mismatch", 1, 0)]
    [InlineData("success", 1, 1)]
    public async Task Retention_requires_a_successful_issued_verdict(string outcome, int expectedActivation, int expectedRetention)
    {
        using var cancellation = new CancellationTokenSource();
        var activation = 0;
        var retention = 0;
        using var client = new HttpClient(new DelegateHandler(_ =>
        {
            if (outcome == "host") { throw new InvalidOperationException("private-host-detail"); }
            if (outcome == "cancel-after") { cancellation.Cancel(); }
            return new HttpResponseMessage(outcome == "mismatch" ? HttpStatusCode.BadRequest : HttpStatusCode.OK);
        }));
        if (outcome == "cancel-before") { cancellation.Cancel(); }
        var expectation = RateExpectation.Unlimited(outcome == "safety" ? 2 : 1);
        var result = await new RateVerifier(1, () => activation++, () => retention++).VerifyAsync(
            new RateContract(client, RateScenario.Unlimited(_ =>
            {
                if (outcome == "factory") { throw new InvalidOperationException(); }
                if (outcome == "factory-cancel") { throw new OperationCanceledException(); }
                return Request();
            }, expectation)), cancellation.Token);
        Assert.Equal(outcome == "success", result.Succeeded);
        Assert.Equal(expectedActivation, activation);
        Assert.Equal(expectedRetention, retention);
    }

    private static object[] Case(string shape, int accepted, int rejected, RateVerificationFailureKind expected, params int[] statuses) => new object[] { shape, accepted, rejected, statuses, expected };

    private static RateExpectation CreateExpectation(int factory, IReadOnlyDictionary<string, Func<string?, bool>> headers) => factory == 0
        ? RateExpectation.Burst(1, rejectedHeaderPredicates: headers)
        : RateExpectation.BurstWithSuccessStatusRange(1, 200, 299, rejectedHeaderPredicates: headers);

    private static HttpRequestMessage Request() => new(HttpMethod.Get, "http://local.test/");

    private static RateScenario Scenario(string shape, RateRequestFactory factory, RateExpectation expectation) => shape switch
    {
        "burst" => RateScenario.InitialBurst(factory, expectation),
        "isolation" => RateScenario.PartitionIsolation(factory, factory, expectation),
        "shared" => RateScenario.SharedPartition(factory, factory, expectation),
        "unlimited" => RateScenario.Unlimited(factory, expectation),
        _ => throw new ArgumentOutOfRangeException(nameof(shape))
    };

    private sealed class DelegateHandler(Func<HttpRequestMessage, HttpResponseMessage> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => Task.FromResult(send(request));
    }

    private sealed class CleanupContent(Action cleanup) : HttpContent
    {
        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) => Task.CompletedTask;
        protected override bool TryComputeLength(out long length) { length = 0; return true; }
        protected override void Dispose(bool disposing) { if (disposing) { cleanup(); } base.Dispose(disposing); }
    }
}
