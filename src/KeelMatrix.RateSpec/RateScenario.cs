namespace KeelMatrix.RateSpec;

/// <summary>Identifies the bounded observable behavior exercised by a scenario.</summary>
public enum RateScenarioKind
{
    /// <summary>Checks an accepted burst followed by a rejection.</summary>
    InitialBurst,

    /// <summary>Checks that two request factories use independent partitions.</summary>
    PartitionIsolation,

    /// <summary>Checks that two request factories intentionally observe shared budget.</summary>
    SharedPartition,

    /// <summary>Checks a bounded request sequence on an endpoint expected to remain unlimited.</summary>
    Unlimited
}

/// <summary>Describes one bounded rate-limit behavior check.</summary>
public sealed class RateScenario
{
    private RateScenario(
        RateScenarioKind kind,
        RateRequestFactory firstRequestFactory,
        RateRequestFactory? secondRequestFactory,
        RateExpectation expectation)
    {
        Kind = kind;
        FirstRequestFactory = firstRequestFactory;
        SecondRequestFactory = secondRequestFactory;
        Expectation = expectation;
    }

    /// <summary>Gets the scenario behavior.</summary>
    public RateScenarioKind Kind { get; }

    /// <summary>Gets the expectation shared by this scenario's request phases.</summary>
    public RateExpectation Expectation { get; }

    /// <summary>Creates an initial-burst scenario.</summary>
    /// <param name="requestFactory">Creates requests for the endpoint and partition under test.</param>
    /// <param name="expectation">A burst expectation.</param>
    /// <returns>A bounded initial-burst scenario.</returns>
    public static RateScenario InitialBurst(RateRequestFactory requestFactory, RateExpectation expectation)
    {
        ArgumentNullException.ThrowIfNull(requestFactory);
        ArgumentNullException.ThrowIfNull(expectation);
        expectation.Validate();
        if (expectation.IsUnlimited)
        {
            throw new ArgumentException("An initial-burst scenario requires a burst expectation.", nameof(expectation));
        }

        return new(RateScenarioKind.InitialBurst, requestFactory, null, expectation);
    }

    /// <summary>Creates a partition-isolation scenario.</summary>
    /// <param name="partitionARequestFactory">Creates requests for the first application partition.</param>
    /// <param name="partitionBRequestFactory">Creates requests for the second application partition.</param>
    /// <param name="expectation">A burst expectation used for both partitions.</param>
    /// <returns>A bounded partition-isolation scenario.</returns>
    public static RateScenario PartitionIsolation(
        RateRequestFactory partitionARequestFactory,
        RateRequestFactory partitionBRequestFactory,
        RateExpectation expectation)
    {
        ValidatePartitionScenario(partitionARequestFactory, partitionBRequestFactory, expectation);
        return new(RateScenarioKind.PartitionIsolation, partitionARequestFactory, partitionBRequestFactory, expectation);
    }

    /// <summary>Creates a shared-partition scenario.</summary>
    /// <param name="firstRequestFactory">Creates requests for the first view of the shared partition.</param>
    /// <param name="secondRequestFactory">Creates requests for the second view of the shared partition.</param>
    /// <param name="expectation">A burst expectation used for the shared budget.</param>
    /// <returns>A bounded shared-partition scenario.</returns>
    public static RateScenario SharedPartition(
        RateRequestFactory firstRequestFactory,
        RateRequestFactory secondRequestFactory,
        RateExpectation expectation)
    {
        ValidatePartitionScenario(firstRequestFactory, secondRequestFactory, expectation);
        return new(RateScenarioKind.SharedPartition, firstRequestFactory, secondRequestFactory, expectation);
    }

    /// <summary>Creates a bounded scenario for an endpoint expected to remain unlimited.</summary>
    /// <param name="requestFactory">Creates requests for the endpoint under test.</param>
    /// <param name="expectation">An unlimited expectation with the desired bounded request count.</param>
    /// <returns>A bounded unlimited-endpoint scenario.</returns>
    public static RateScenario Unlimited(RateRequestFactory requestFactory, RateExpectation expectation)
    {
        ArgumentNullException.ThrowIfNull(requestFactory);
        ArgumentNullException.ThrowIfNull(expectation);
        expectation.Validate();
        if (!expectation.IsUnlimited)
        {
            throw new ArgumentException("An unlimited scenario requires an unlimited expectation.", nameof(expectation));
        }

        return new(RateScenarioKind.Unlimited, requestFactory, null, expectation);
    }

    internal RateRequestFactory FirstRequestFactory { get; }

    internal RateRequestFactory? SecondRequestFactory { get; }

    internal int ExpectedRequestCount => Kind switch
    {
        RateScenarioKind.InitialBurst => Expectation.AcceptedRequestCount + 1,
        RateScenarioKind.Unlimited => Expectation.AcceptedRequestCount,
        RateScenarioKind.PartitionIsolation => checked((Expectation.AcceptedRequestCount + 1) * 2),
        RateScenarioKind.SharedPartition => checked(Expectation.AcceptedRequestCount + 2),
        _ => throw new InvalidOperationException("Unknown scenario kind.")
    };

    private static void ValidatePartitionScenario(
        RateRequestFactory firstRequestFactory,
        RateRequestFactory secondRequestFactory,
        RateExpectation expectation)
    {
        ArgumentNullException.ThrowIfNull(firstRequestFactory);
        ArgumentNullException.ThrowIfNull(secondRequestFactory);
        ArgumentNullException.ThrowIfNull(expectation);
        expectation.Validate();
        if (expectation.IsUnlimited)
        {
            throw new ArgumentException("A partition scenario requires a burst expectation.", nameof(expectation));
        }
    }
}

