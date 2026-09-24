namespace KeelMatrix.RateSpec;

/// <summary>Groups one or more observable rate-limit scenarios for one HTTP client.</summary>
public sealed class RateContract
{
    /// <summary>Creates a contract containing one scenario.</summary>
    /// <param name="client">The caller-owned HTTP client connected to the test host.</param>
    /// <param name="scenario">The bounded scenario to execute.</param>
    public RateContract(HttpClient client, RateScenario scenario)
        : this(client, new[] { scenario })
    {
    }

    /// <summary>Creates a contract containing an ordered set of scenarios.</summary>
    /// <param name="client">The caller-owned HTTP client connected to the test host.</param>
    /// <param name="scenarios">The bounded scenarios to execute in order.</param>
    public RateContract(HttpClient client, IEnumerable<RateScenario> scenarios)
    {
        Client = client ?? throw new ArgumentNullException(nameof(client));
        ArgumentNullException.ThrowIfNull(scenarios);

        var materialized = scenarios.ToArray();
        if (materialized.Length == 0)
        {
            throw new ArgumentException("A rate contract must contain at least one scenario.", nameof(scenarios));
        }

        if (materialized.Any(static scenario => scenario is null))
        {
            throw new ArgumentException("A rate contract cannot contain a null scenario.", nameof(scenarios));
        }

        Scenarios = materialized;
    }

    /// <summary>Gets the caller-owned HTTP client used for all scenarios.</summary>
    public HttpClient Client { get; }

    /// <summary>Gets the ordered, immutable scenario set.</summary>
    public IReadOnlyList<RateScenario> Scenarios { get; }
}

