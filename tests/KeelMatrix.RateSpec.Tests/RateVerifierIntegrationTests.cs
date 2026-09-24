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

        var result = await VerifyAsync(
            client,
            RateScenario.SharedPartition(
                _ => Request("/partitioned", "same"),
                _ => Request("/partitioned", "same"),
                RateExpectation.Burst(2)));

        Assert.True(result.Succeeded, result.Message);
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

    private static async Task<RateVerificationResult> VerifyAsync(HttpClient client, RateScenario scenario) =>
        await new RateVerifier().VerifyAsync(new RateContract(client, scenario));

    private static HttpRequestMessage Request(string path, string partition)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, path);
        request.Headers.Add("X-Partition", partition);
        return request;
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
