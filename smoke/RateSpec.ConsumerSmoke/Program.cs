using System.Threading.RateLimiting;
using KeelMatrix.RateSpec;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;

var builder = new WebHostBuilder()
    .ConfigureServices(services =>
    {
        services.AddRouting();
        services.AddRateLimiter(options => options.AddPolicy(
            "partitioned",
            context => RateLimitPartition.GetFixedWindowLimiter(
                context.Request.Headers["X-Partition"].ToString(),
                _ => new FixedWindowRateLimiterOptions
                {
                    PermitLimit = 2,
                    QueueLimit = 0,
                    Window = TimeSpan.FromMinutes(10),
                    AutoReplenishment = false
                })));
    })
    .Configure(app =>
    {
        app.UseRouting();
        app.UseRateLimiter();
        app.UseEndpoints(endpoints => endpoints
            .MapGet("/limited", () => Results.Ok())
            .RequireRateLimiting("partitioned"));
    });

using var server = new TestServer(builder);
using var client = server.CreateClient();

var result = await new RateVerifier().VerifyAsync(
    new RateContract(
        client,
        RateScenario.PartitionIsolation(
            _ => CreateRequest("A"),
            _ => CreateRequest("B"),
            RateExpectation.Burst(2))));

if (!result.Succeeded)
{
    throw new InvalidOperationException(result.Message);
}

Console.WriteLine("Package consumer smoke passed.");

static HttpRequestMessage CreateRequest(string partition)
{
    var request = new HttpRequestMessage(HttpMethod.Get, "/limited");
    request.Headers.Add("X-Partition", partition);
    return request;
}
