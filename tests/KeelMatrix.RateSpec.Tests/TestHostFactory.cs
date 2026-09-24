using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.AspNetCore.Routing;
using System.Threading.RateLimiting;

namespace KeelMatrix.RateSpec.Tests;

internal static class TestHostFactory
{
    internal static TestServer Create(
        Action<RateLimiterOptions>? configureRateLimiter,
        Action<IEndpointRouteBuilder> configureEndpoints)
    {
        var builder = new WebHostBuilder()
            .ConfigureServices(services =>
            {
                services.AddRouting();
                services.AddRateLimiter(options => configureRateLimiter?.Invoke(options));
            })
            .Configure(app =>
            {
                app.UseRouting();
                app.UseRateLimiter();
                app.UseEndpoints(configureEndpoints);
            });

        return new TestServer(builder);
    }

    internal static RateLimitPartition<string> FixedPartition(string key, int permitLimit) =>
        RateLimitPartition.GetFixedWindowLimiter(
            key,
            _ => new FixedWindowRateLimiterOptions
            {
                PermitLimit = permitLimit,
                QueueLimit = 0,
                Window = TimeSpan.FromMinutes(10),
                AutoReplenishment = false
            });
}
