using System.Net;
using System.Net.Http.Headers;
using System.Threading.RateLimiting;
using KeelMatrix.RateSpec;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.RateLimiting;
using Xunit;

namespace KeelMatrix.RateSpec.Tests;

public sealed class RateVerifierIntegrationTests
{
    [Fact]
    public async Task Fixed_window_accepts_initial_burst_then_rejects()
    {
        using var server = TestHostFactory.Create(
            options => options.AddFixedWindowLimiter("fixed", limiter =>
            {
                limiter.PermitLimit = 3;
                limiter.QueueLimit = 0;
                limiter.Window = TimeSpan.FromMinutes(10);
                limiter.AutoReplenishment = false;
            }),
            endpoints => endpoints.MapGet("/limited", () => Results.Ok()).RequireRateLimiting("fixed"));
        using var client = server.CreateClient();

        var result = await VerifyAsync(
            client,
            RateScenario.InitialBurst(
                _ => new HttpRequestMessage(HttpMethod.Get, "/limited"),
                RateExpectation.Burst(3)));

        Assert.True(result.Succeeded, result.Message);
        Assert.Equal(4, result.RequestsIssued);
    }

    [Fact]
    public async Task Token_bucket_initial_capacity_is_observable_without_replenishment()
    {
        using var server = TestHostFactory.Create(
            options => options.AddTokenBucketLimiter("tokens", limiter =>
            {
                limiter.TokenLimit = 2;
                limiter.TokensPerPeriod = 1;
                limiter.ReplenishmentPeriod = TimeSpan.FromMinutes(10);
                limiter.QueueLimit = 0;
                limiter.AutoReplenishment = false;
            }),
            endpoints => endpoints.MapGet("/tokens", () => Results.NoContent()).RequireRateLimiting("tokens"));
        using var client = server.CreateClient();

        var result = await VerifyAsync(
            client,
            RateScenario.InitialBurst(
                _ => new HttpRequestMessage(HttpMethod.Get, "/tokens"),
                RateExpectation.BurstWithSuccessStatusRange(2, 200, 299)));

        Assert.True(result.Succeeded, result.Message);
    }

    [Fact]
    public async Task Sliding_window_initial_capacity_is_observable_without_replenishment()
    {
        using var server = TestHostFactory.Create(
            options => options.AddSlidingWindowLimiter("sliding", limiter =>
            {
                limiter.PermitLimit = 2;
                limiter.SegmentsPerWindow = 2;
                limiter.Window = TimeSpan.FromMinutes(10);
                limiter.QueueLimit = 0;
                limiter.AutoReplenishment = false;
            }),
            endpoints => endpoints.MapGet("/sliding", () => Results.Ok()).RequireRateLimiting("sliding"));
        using var client = server.CreateClient();

        var result = await VerifyAsync(
            client,
            RateScenario.InitialBurst(
                _ => new HttpRequestMessage(HttpMethod.Get, "/sliding"),
                RateExpectation.Burst(2)));

        Assert.True(result.Succeeded, result.Message);
    }

    [Fact]
    public async Task Different_partitions_keep_independent_budgets()
    {
        using var server = TestHostFactory.Create(
            options => options.AddPolicy("partitioned", context =>
                TestHostFactory.FixedPartition(context.Request.Headers["X-Partition"].ToString(), 2)),
            endpoints => endpoints.MapGet("/partitioned", () => Results.Ok()).RequireRateLimiting("partitioned"));
        using var client = server.CreateClient();

        var result = await VerifyAsync(
            client,
            RateScenario.PartitionIsolation(
                _ => Request("/partitioned", "A"),
                _ => Request("/partitioned", "B"),
                RateExpectation.Burst(2)));

        Assert.True(result.Succeeded, result.Message);
    }

    [Fact]
    public async Task Shared_partition_is_expected_to_share_budget()
    {
        using var server = TestHostFactory.Create(
            options => options.AddPolicy("partitioned", context =>
                TestHostFactory.FixedPartition(context.Request.Headers["X-Partition"].ToString(), 2)),
            endpoints => endpoints.MapGet("/partitioned", () => Results.Ok()).RequireRateLimiting("partitioned"));
        using var client = server.CreateClient();
        var firstRequestNumbers = new List<int>();
        var secondRequestNumbers = new List<int>();

        var result = await VerifyAsync(
            client,
            RateScenario.SharedPartition(
                requestNumber =>
                {
                    firstRequestNumbers.Add(requestNumber);
                    return Request("/partitioned", "same");
                },
                requestNumber =>
                {
                    secondRequestNumbers.Add(requestNumber);
                    return Request("/partitioned", "same");
                },
                RateExpectation.Burst(2)));

        Assert.True(result.Succeeded, result.Message);
        Assert.Equal(3, firstRequestNumbers.Count);
        Assert.Equal(0, firstRequestNumbers[0]);
        Assert.Equal(1, firstRequestNumbers[1]);
        Assert.Equal(2, firstRequestNumbers[2]);
        Assert.Single(secondRequestNumbers);
        Assert.Equal(0, secondRequestNumbers[0]);
    }

    [Fact]
    public async Task Named_policies_with_equal_partition_keys_stay_isolated()
    {
        using var server = TestHostFactory.Create(
            options =>
            {
                options.AddPolicy("loose", context => TestHostFactory.FixedPartition("same", 3));
                options.AddPolicy("tight", context => TestHostFactory.FixedPartition("same", 1));
            },
            endpoints =>
            {
                endpoints.MapGet("/loose", () => Results.Ok()).RequireRateLimiting("loose");
                endpoints.MapGet("/tight", () => Results.Ok()).RequireRateLimiting("tight");
            });
        using var client = server.CreateClient();

        var result = await new RateVerifier().VerifyAsync(
            new RateContract(
                client,
                new[]
                {
                    RateScenario.InitialBurst(
                        _ => Request("/loose", "same"),
                        RateExpectation.Burst(3)),
                    RateScenario.InitialBurst(
                        _ => Request("/tight", "same"),
                        RateExpectation.Burst(1))
                }));

        Assert.True(result.Succeeded, result.Message);
    }

    [Fact]
    public async Task Inline_policy_partition_collision_is_reported_as_a_per_endpoint_failure()
    {
        // This mirrors the same-key loose-before-tight shape from https://github.com/dotnet/aspnetcore/issues/67326.
        using var server = TestHostFactory.Create(
            _ => { },
            endpoints =>
            {
                endpoints.MapGet("/loose", () => Results.Ok())
                    .RequireRateLimiting(new InlinePolicy(permitLimit: 1000));
                endpoints.MapGet("/tight", () => Results.Ok())
                    .RequireRateLimiting(new InlinePolicy(permitLimit: 2));
            });
        using var client = server.CreateClient();

        var result = await new RateVerifier().VerifyAsync(
            new RateContract(
                client,
                new[]
                {
                    RateScenario.Unlimited(
                        _ => RequestWithClient("/loose", "alice"),
                        RateExpectation.Unlimited(3)),
                    RateScenario.InitialBurst(
                        _ => RequestWithClient("/tight", "alice"),
                        RateExpectation.Burst(2))
                }));

        Assert.False(result.Succeeded);
        Assert.Equal(RateVerificationFailureKind.MissingRejection, result.FailureKind);
        Assert.True(result.Scenarios[0].Succeeded, result.Scenarios[0].Message);
        Assert.False(result.Scenarios[1].Succeeded);
    }

    [Fact]
    public async Task Endpoint_without_a_limiter_remains_unlimited_for_the_bounded_check()
    {
        using var server = TestHostFactory.Create(
            _ => { },
            endpoints => endpoints.MapGet("/unlimited", () => Results.Ok()));
        using var client = server.CreateClient();

        var result = await VerifyAsync(
            client,
            RateScenario.Unlimited(
                _ => new HttpRequestMessage(HttpMethod.Get, "/unlimited"),
                RateExpectation.Unlimited(5)));

        Assert.True(result.Succeeded, result.Message);
    }

    [Fact]
    public async Task Mid_burst_request_factory_failure_is_classified_without_a_false_pass()
    {
        var sent = 0;
        using var client = new HttpClient(new CountingHandler(() => sent++));

        var result = await VerifyAsync(
            client,
            RateScenario.InitialBurst(
                requestNumber => requestNumber == 1
                    ? throw new InvalidOperationException("factory failure")
                    : new HttpRequestMessage(HttpMethod.Get, "http://local.test/"),
                RateExpectation.Burst(2)));

        Assert.False(result.Succeeded);
        Assert.Equal(RateVerificationFailureKind.HostFailure, result.FailureKind);
        Assert.Equal(1, sent);
        Assert.DoesNotContain("factory failure", result.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Partial_rejection_before_the_declared_burst_does_not_pass()
    {
        using var server = TestHostFactory.Create(
            options => options.AddFixedWindowLimiter("partial", limiter =>
            {
                limiter.PermitLimit = 1;
                limiter.QueueLimit = 0;
                limiter.Window = TimeSpan.FromMinutes(10);
                limiter.AutoReplenishment = false;
            }),
            endpoints => endpoints.MapGet("/partial", () => Results.Ok()).RequireRateLimiting("partial"));
        using var client = server.CreateClient();

        var result = await VerifyAsync(
            client,
            RateScenario.InitialBurst(
                _ => new HttpRequestMessage(HttpMethod.Get, "/partial"),
                RateExpectation.Burst(2)));

        Assert.False(result.Succeeded);
        Assert.Equal(RateVerificationFailureKind.EarlyRejection, result.FailureKind);
    }

    [Fact]
    public async Task Endpoint_that_never_rejects_does_not_pass_a_required_rejection()
    {
        using var server = TestHostFactory.Create(
            _ => { },
            endpoints => endpoints.MapGet("/never-rejects", () => Results.Ok()));
        using var client = server.CreateClient();

        var result = await VerifyAsync(
            client,
            RateScenario.InitialBurst(
                _ => new HttpRequestMessage(HttpMethod.Get, "/never-rejects"),
                RateExpectation.Burst(1)));

        Assert.False(result.Succeeded);
        Assert.Equal(RateVerificationFailureKind.MissingRejection, result.FailureKind);
    }

    [Fact]
    public async Task Custom_rejection_status_and_header_are_checked_generically()
    {
        using var server = TestHostFactory.Create(
            options =>
            {
                options.RejectionStatusCode = StatusCodes.Status418ImATeapot;
                options.AddFixedWindowLimiter("custom", limiter =>
                {
                    limiter.PermitLimit = 1;
                    limiter.QueueLimit = 0;
                    limiter.Window = TimeSpan.FromMinutes(10);
                    limiter.AutoReplenishment = false;
                });
                options.OnRejected = (context, _) =>
                {
                    context.HttpContext.Response.Headers["X-RateSpec-Decision"] = "rejected";
                    return ValueTask.CompletedTask;
                };
            },
            endpoints => endpoints.MapGet("/custom", () => Results.Ok()).RequireRateLimiting("custom"));
        using var client = server.CreateClient();

        var result = await VerifyAsync(
            client,
            RateScenario.InitialBurst(
                _ => new HttpRequestMessage(HttpMethod.Get, "/custom"),
                RateExpectation.Burst(
                    1,
                    rejectionStatusCode: StatusCodes.Status418ImATeapot,
                    rejectedHeaderPredicates: new Dictionary<string, Func<string?, bool>>
                    {
                        ["X-RateSpec-Decision"] = value => value == "rejected"
                    })));

        Assert.True(result.Succeeded, result.Message);
    }

    [Fact]
    public void Custom_rejection_predicate_cannot_overrule_default_accepted_status()
    {
        Assert.Throws<ArgumentException>(() => RateExpectation.Burst(
            1,
            rejectedPredicate: _ => true,
            rejectionStatusCode: StatusCodes.Status204NoContent,
            rejectedHeaderPredicates: new Dictionary<string, Func<string?, bool>>
            {
                ["X-RateSpec-Decision"] = value => value == "rejected"
            }));
    }

    [Fact]
    public void Custom_accepted_predicate_cannot_use_default_rejection_for_a_success_status()
    {
        Assert.Throws<ArgumentException>(() => RateExpectation.Burst(
            1,
            acceptedPredicate: _ => true,
            rejectionStatusCode: StatusCodes.Status200OK));
    }

    [Fact]
    public async Task Rejection_matching_both_custom_predicates_cannot_pass()
    {
        using var client = new HttpClient(new StatusHandler(_ => HttpStatusCode.TooManyRequests));

        var result = await VerifyAsync(
            client,
            RateScenario.InitialBurst(
                _ => new HttpRequestMessage(HttpMethod.Get, "http://local.test/"),
                RateExpectation.Burst(
                    1,
                    acceptedPredicate: _ => true,
                    rejectedPredicate: _ => true,
                    rejectionStatusCode: StatusCodes.Status429TooManyRequests)));

        Assert.False(result.Succeeded);
        Assert.Equal(RateVerificationFailureKind.StatusMismatch, result.FailureKind);
        Assert.Equal(2, result.RequestsIssued);
        Assert.Contains("also matched", result.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Rejection_matching_custom_acceptance_cannot_pass_with_default_rejection()
    {
        using var client = new HttpClient(new StatusHandler(_ => HttpStatusCode.TooManyRequests));

        var result = await VerifyAsync(
            client,
            RateScenario.InitialBurst(
                _ => new HttpRequestMessage(HttpMethod.Get, "http://local.test/"),
                RateExpectation.Burst(
                    1,
                    acceptedPredicate: _ => true,
                    rejectionStatusCode: StatusCodes.Status429TooManyRequests)));

        Assert.False(result.Succeeded);
        Assert.Equal(RateVerificationFailureKind.StatusMismatch, result.FailureKind);
        Assert.Equal(2, result.RequestsIssued);
    }

    [Fact]
    public async Task Cancellation_stops_an_in_flight_request_without_retrying()
    {
        using var cancellationSource = new CancellationTokenSource();
        var calls = 0;
        using var client = new HttpClient(new CancellationHandler(() =>
        {
            calls++;
            cancellationSource.Cancel();
        }));

        var result = await new RateVerifier().VerifyAsync(
            new RateContract(
                client,
                RateScenario.InitialBurst(
                    _ => new HttpRequestMessage(HttpMethod.Get, "http://local.test/"),
                    RateExpectation.Burst(2))),
            cancellationSource.Token);

        Assert.False(result.Succeeded);
        Assert.Equal(RateVerificationFailureKind.Cancelled, result.FailureKind);
        Assert.Equal(1, calls);
        Assert.Equal(1, result.RequestsIssued);
    }

    [Theory]
    [InlineData("initial")]
    [InlineData("unlimited")]
    [InlineData("partition")]
    [InlineData("shared")]
    public async Task Factory_operation_cancellation_is_classified_as_cancelled_for_every_shape(string scenarioKind)
    {
        var handler = new StatusHandler(_ => HttpStatusCode.OK);
        using var client = new HttpClient(handler);
        var cancelledFactory = new RateRequestFactory(_ => throw new OperationCanceledException());
        var ordinaryFactory = new RateRequestFactory(_ => new HttpRequestMessage(HttpMethod.Get, "http://local.test/"));
        var scenario = scenarioKind switch
        {
            "initial" => RateScenario.InitialBurst(cancelledFactory, RateExpectation.Burst(1)),
            "unlimited" => RateScenario.Unlimited(cancelledFactory, RateExpectation.Unlimited(1)),
            "partition" => RateScenario.PartitionIsolation(cancelledFactory, ordinaryFactory, RateExpectation.Burst(1)),
            "shared" => RateScenario.SharedPartition(cancelledFactory, ordinaryFactory, RateExpectation.Burst(1)),
            _ => throw new ArgumentOutOfRangeException(nameof(scenarioKind))
        };

        var activationCalls = 0;
        var result = await new RateVerifier(100, () => activationCalls++)
            .VerifyAsync(new RateContract(client, scenario));

        Assert.False(result.Succeeded);
        Assert.Equal(RateVerificationFailureKind.Cancelled, result.FailureKind);
        Assert.Equal(0, result.RequestsIssued);
        Assert.Equal(0, handler.Calls);
        Assert.Equal(0, result.Scenarios.Single().RequestsIssued);
        Assert.Equal(0, activationCalls);
    }

    [Theory]
    [InlineData("initial")]
    [InlineData("unlimited")]
    [InlineData("partition")]
    [InlineData("shared")]
    public async Task Cancellation_before_factory_creation_issues_no_request_for_every_shape(string scenarioKind)
    {
        using var cancellationSource = new CancellationTokenSource();
        cancellationSource.Cancel();
        var factoryCalls = 0;
        using var client = new HttpClient(new CountingHandler(() => { }));
        var factory = new RateRequestFactory(_ =>
        {
            factoryCalls++;
            return new HttpRequestMessage(HttpMethod.Get, "http://local.test/");
        });
        var scenario = scenarioKind switch
        {
            "initial" => RateScenario.InitialBurst(factory, RateExpectation.Burst(1)),
            "unlimited" => RateScenario.Unlimited(factory, RateExpectation.Unlimited(1)),
            "partition" => RateScenario.PartitionIsolation(factory, factory, RateExpectation.Burst(1)),
            "shared" => RateScenario.SharedPartition(factory, factory, RateExpectation.Burst(1)),
            _ => throw new ArgumentOutOfRangeException(nameof(scenarioKind))
        };

        var activationCalls = 0;
        var result = await new RateVerifier(100, () => activationCalls++)
            .VerifyAsync(new RateContract(client, scenario), cancellationSource.Token);

        Assert.False(result.Succeeded);
        Assert.Equal(RateVerificationFailureKind.Cancelled, result.FailureKind);
        Assert.Equal(0, result.RequestsIssued);
        Assert.Empty(result.Scenarios);
        Assert.Equal(0, factoryCalls);
        Assert.Equal(0, activationCalls);
    }

    [Fact]
    public async Task Cancellation_between_unlimited_requests_preserves_prior_observation()
    {
        using var cancellationSource = new CancellationTokenSource();
        using var client = new HttpClient(new StatusHandler(
            _ => HttpStatusCode.OK,
            callNumber =>
            {
                if (callNumber == 0)
                {
                    cancellationSource.Cancel();
                }
            }));

        var activationCalls = 0;
        var result = await new RateVerifier(100, () => activationCalls++).VerifyAsync(
            new RateContract(
                client,
                RateScenario.Unlimited(
                    _ => new HttpRequestMessage(HttpMethod.Get, "http://local.test/"),
                    RateExpectation.Unlimited(3))),
            cancellationSource.Token);

        Assert.False(result.Succeeded);
        Assert.Equal(RateVerificationFailureKind.Cancelled, result.FailureKind);
        Assert.Equal(1, result.RequestsIssued);
        Assert.Equal(1, result.Scenarios.Single().Observations.Count(observation => observation.StatusCode is not null));
        Assert.Equal(200, result.Scenarios.Single().Observations[0].StatusCode);
        Assert.Equal(1, activationCalls);
    }

    [Theory]
    [InlineData("partition")]
    [InlineData("shared")]
    public async Task Cancellation_between_partition_phases_preserves_prior_observations(string scenarioKind)
    {
        using var cancellationSource = new CancellationTokenSource();
        using var client = new HttpClient(new StatusHandler(
            callNumber => callNumber == 0 ? HttpStatusCode.OK : HttpStatusCode.TooManyRequests,
            callNumber =>
            {
                if (callNumber == 1)
                {
                    cancellationSource.Cancel();
                }
            }));

        var firstFactoryCalls = 0;
        var secondFactoryCalls = 0;
        var firstFactory = new RateRequestFactory(_ =>
        {
            firstFactoryCalls++;
            return new HttpRequestMessage(HttpMethod.Get, "http://local.test/");
        });
        var secondFactory = new RateRequestFactory(_ =>
        {
            secondFactoryCalls++;
            return new HttpRequestMessage(HttpMethod.Get, "http://local.test/");
        });
        var scenario = scenarioKind == "partition"
            ? RateScenario.PartitionIsolation(firstFactory, secondFactory, RateExpectation.Burst(1))
            : RateScenario.SharedPartition(firstFactory, secondFactory, RateExpectation.Burst(1));

        var activationCalls = 0;
        var result = await new RateVerifier(100, () => activationCalls++)
            .VerifyAsync(new RateContract(client, scenario), cancellationSource.Token);

        Assert.False(result.Succeeded);
        Assert.Equal(RateVerificationFailureKind.Cancelled, result.FailureKind);
        Assert.Equal(2, result.RequestsIssued);
        Assert.Equal(2, result.Scenarios.Single().Observations.Count(observation => observation.StatusCode is not null));
        Assert.Equal(2, firstFactoryCalls);
        Assert.Equal(0, secondFactoryCalls);
        Assert.Equal(1, activationCalls);
    }

    [Fact]
    public async Task Safety_ceiling_fails_before_issuing_requests()
    {
        var calls = 0;
        using var client = new HttpClient(new CountingHandler(() => calls++));
        var result = await new RateVerifier(maximumRequestCount: 3).VerifyAsync(
            new RateContract(
                client,
                RateScenario.InitialBurst(
                    _ => new HttpRequestMessage(HttpMethod.Get, "http://local.test/"),
                    RateExpectation.Burst(3))));

        Assert.False(result.Succeeded);
        Assert.Equal(RateVerificationFailureKind.SafetyCeilingExceeded, result.FailureKind);
        Assert.Equal(0, result.RequestsIssued);
        Assert.Equal(0, calls);
    }

    [Fact]
    public async Task Failed_verdict_after_a_request_tracks_activation()
    {
        var activationCalls = 0;
        using var client = new HttpClient(new CountingHandler(() => { }));

        var result = await new RateVerifier(100, () => activationCalls++).VerifyAsync(
            new RateContract(
                client,
                RateScenario.InitialBurst(
                    _ => new HttpRequestMessage(HttpMethod.Get, "http://local.test/"),
                    RateExpectation.Burst(1))));

        Assert.False(result.Succeeded);
        Assert.Equal(RateVerificationFailureKind.MissingRejection, result.FailureKind);
        Assert.Equal(2, result.RequestsIssued);
        Assert.Equal(1, activationCalls);
    }

    [Fact]
    public async Task Verdict_with_no_request_issued_does_not_track_activation()
    {
        var activationCalls = 0;
        var factoryCalls = 0;
        using var client = new HttpClient(new CountingHandler(() => { }));

        var result = await new RateVerifier(1, () => activationCalls++).VerifyAsync(
            new RateContract(
                client,
                RateScenario.InitialBurst(
                    _ =>
                    {
                        factoryCalls++;
                        return new HttpRequestMessage(HttpMethod.Get, "http://local.test/");
                    },
                    RateExpectation.Burst(1))));

        Assert.False(result.Succeeded);
        Assert.Equal(RateVerificationFailureKind.SafetyCeilingExceeded, result.FailureKind);
        Assert.Equal(0, result.RequestsIssued);
        Assert.Equal(0, factoryCalls);
        Assert.Equal(0, activationCalls);
    }

    [Theory]
    [InlineData("initial", 1)]
    [InlineData("unlimited", 1)]
    [InlineData("partition", 2)]
    [InlineData("shared", 2)]
    public async Task Factory_failures_count_only_requests_handed_to_http_client(string scenarioKind, int expectedRequestsIssued)
    {
        var factoryCalls = 0;
        var handler = new StatusHandler(callNumber => callNumber == 0 ? HttpStatusCode.OK : HttpStatusCode.TooManyRequests);
        using var client = new HttpClient(handler);

        var scenario = scenarioKind switch
        {
            "initial" => RateScenario.InitialBurst(
                _ =>
                {
                    factoryCalls++;
                    if (factoryCalls == 2)
                    {
                        throw new InvalidOperationException();
                    }

                    return new HttpRequestMessage(HttpMethod.Get, "http://local.test/");
                },
                RateExpectation.Burst(1)),
            "unlimited" => RateScenario.Unlimited(
                _ =>
                {
                    factoryCalls++;
                    return factoryCalls == 1
                        ? new HttpRequestMessage(HttpMethod.Get, "http://local.test/")
                        : null!;
                },
                RateExpectation.Unlimited(2)),
            "partition" => RateScenario.PartitionIsolation(
                _ => new HttpRequestMessage(HttpMethod.Get, "http://local.test/"),
                _ => null!,
                RateExpectation.Burst(1)),
            "shared" => RateScenario.SharedPartition(
                _ => new HttpRequestMessage(HttpMethod.Get, "http://local.test/"),
                _ => null!,
                RateExpectation.Burst(1)),
            _ => throw new ArgumentOutOfRangeException(nameof(scenarioKind))
        };

        var result = await VerifyAsync(client, scenario);

        Assert.False(result.Succeeded);
        Assert.Equal(expectedRequestsIssued, result.RequestsIssued);
        Assert.Equal(expectedRequestsIssued, result.Scenarios.Single().RequestsIssued);
        Assert.Equal(expectedRequestsIssued, handler.Calls);
    }

    [Fact]
    public async Task Factory_failure_before_first_request_reports_zero_issued_requests()
    {
        using var client = new HttpClient(new StatusHandler(_ => HttpStatusCode.OK));

        var result = await VerifyAsync(
            client,
            RateScenario.InitialBurst(
                _ => throw new InvalidOperationException(),
                RateExpectation.Burst(1)));

        Assert.False(result.Succeeded);
        Assert.Equal(RateVerificationFailureKind.HostFailure, result.FailureKind);
        Assert.Equal(0, result.RequestsIssued);
        Assert.Equal(0, result.Scenarios.Single().RequestsIssued);
    }

    [Fact]
    public async Task Failure_diagnostics_do_not_echo_factory_exception_details()
    {
        const string secret = "tenant-secret-value";
        using var client = new HttpClient(new CountingHandler(() => throw new InvalidOperationException(secret)));
        var result = await new RateVerifier().VerifyAsync(
            new RateContract(
                client,
                RateScenario.InitialBurst(
                    _ => throw new InvalidOperationException(secret),
                    RateExpectation.Burst(1))));

        Assert.False(result.Succeeded);
        Assert.DoesNotContain(secret, result.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Contradictory_status_range_fails_before_execution()
    {
        Assert.Throws<ArgumentException>(() => RateExpectation.BurstWithSuccessStatusRange(1, 200, 299, 204));
        Assert.Throws<ArgumentException>(() => RateExpectation.BurstWithSuccessStatusRange(1, 400, 200));
    }

    [Theory]
    [InlineData(100, 199, 200)]
    [InlineData(100, 199, 299)]
    [InlineData(300, 599, 200)]
    [InlineData(300, 599, 299)]
    public void Status_range_rejects_success_status_at_the_factory_boundary(
        int minimumStatusCode,
        int maximumStatusCode,
        int rejectionStatusCode)
    {
        Assert.Throws<ArgumentException>(() => RateExpectation.BurstWithSuccessStatusRange(
            1,
            minimumStatusCode,
            maximumStatusCode,
            rejectionStatusCode));
    }

    [Theory]
    [InlineData(100, 199, 300)]
    [InlineData(200, 299, 100)]
    [InlineData(200, 299, 599)]
    [InlineData(300, 599, 199)]
    public void Status_range_accepts_valid_non_success_rejection_boundaries(
        int minimumStatusCode,
        int maximumStatusCode,
        int rejectionStatusCode)
    {
        var expectation = RateExpectation.BurstWithSuccessStatusRange(
            1,
            minimumStatusCode,
            maximumStatusCode,
            rejectionStatusCode);

        Assert.Equal(rejectionStatusCode, expectation.RejectionStatusCode);
    }

    [Fact]
    public void Contradictory_default_rejection_status_fails_during_factory_creation()
    {
        Assert.Throws<ArgumentException>(() => RateExpectation.Burst(1, rejectionStatusCode: 200));
    }

    private static async Task<RateVerificationResult> VerifyAsync(HttpClient client, RateScenario scenario) =>
        await new RateVerifier().VerifyAsync(new RateContract(client, scenario));

    private static HttpRequestMessage Request(string path, string partition)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, path);
        request.Headers.Add("X-Partition", partition);
        return request;
    }

    private static HttpRequestMessage RequestWithClient(string path, string client)
    {
        var separator = path.Contains('?') ? '&' : '?';
        return new HttpRequestMessage(HttpMethod.Get, $"{path}{separator}client={client}");
    }

    private sealed class InlinePolicy(int permitLimit) : IRateLimiterPolicy<string>
    {
        public Func<OnRejectedContext, CancellationToken, ValueTask>? OnRejected => null;

        public RateLimitPartition<string> GetPartition(HttpContext context)
        {
            var client = context.Request.Query["client"].ToString();
            return RateLimitPartition.GetFixedWindowLimiter(
                string.IsNullOrEmpty(client) ? "anonymous" : client,
                _ => new FixedWindowRateLimiterOptions
                {
                    PermitLimit = permitLimit,
                    QueueLimit = 0,
                    Window = TimeSpan.FromMinutes(10),
                    AutoReplenishment = false
                });
        }
    }

    private sealed class CountingHandler : HttpMessageHandler
    {
        private readonly Action _onSend;

        internal CountingHandler(Action onSend) => _onSend = onSend;

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            _onSend();
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK));
        }
    }

    private sealed class StatusHandler : HttpMessageHandler
    {
        private readonly Func<int, HttpStatusCode> _statusFactory;
        private readonly Action<int>? _onCall;

        internal StatusHandler(Func<int, HttpStatusCode> statusFactory, Action<int>? onCall = null)
        {
            _statusFactory = statusFactory;
            _onCall = onCall;
        }

        internal int Calls { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var callNumber = Calls++;
            _onCall?.Invoke(callNumber);
            var status = _statusFactory(callNumber);
            return Task.FromResult(new HttpResponseMessage(status));
        }
    }

    private sealed class CancellationHandler : HttpMessageHandler
    {
        private readonly Action _onSend;

        internal CancellationHandler(Action onSend) => _onSend = onSend;

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            _onSend();
            return Task.FromCanceled<HttpResponseMessage>(cancellationToken);
        }
    }
}
