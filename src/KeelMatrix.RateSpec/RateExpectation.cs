namespace KeelMatrix.RateSpec;

/// <summary>Describes the observable response contract for a bounded scenario.</summary>
public sealed class RateExpectation
{
    private RateExpectation(
        int acceptedRequestCount,
        bool isUnlimited,
        Func<HttpResponseMessage, bool> acceptedPredicate,
        Func<HttpResponseMessage, bool> rejectedPredicate,
        int? rejectionStatusCode,
        IReadOnlyDictionary<string, Func<string?, bool>> rejectedHeaderPredicates)
    {
        AcceptedRequestCount = acceptedRequestCount;
        IsUnlimited = isUnlimited;
        AcceptedPredicate = acceptedPredicate;
        RejectedPredicate = rejectedPredicate;
        RejectionStatusCode = rejectionStatusCode;
        RejectedHeaderPredicates = rejectedHeaderPredicates;
    }

    /// <summary>Gets the number of responses expected to satisfy the accepted predicate.</summary>
    public int AcceptedRequestCount { get; }

    /// <summary>Gets a value indicating whether the scenario intentionally has no rejection step.</summary>
    public bool IsUnlimited { get; }

    /// <summary>Gets the predicate applied to each expected accepted response.</summary>
    public Func<HttpResponseMessage, bool> AcceptedPredicate { get; }

    /// <summary>Gets the predicate applied to an expected rejected response.</summary>
    public Func<HttpResponseMessage, bool> RejectedPredicate { get; }

    /// <summary>Gets the optional exact status code expected for the rejection response.</summary>
    public int? RejectionStatusCode { get; }

    /// <summary>Gets predicates applied to headers on the rejection response.</summary>
    public IReadOnlyDictionary<string, Func<string?, bool>> RejectedHeaderPredicates { get; }

    /// <summary>Creates an expectation for an initial accepted burst followed by one rejection.</summary>
    /// <param name="acceptedRequestCount">The number of requests expected to be accepted before rejection.</param>
    /// <param name="acceptedPredicate">Optional predicate for accepted responses; defaults to any 2xx response.</param>
    /// <param name="rejectedPredicate">Optional predicate for the rejection response; defaults to any non-2xx response.</param>
    /// <param name="rejectionStatusCode">Optional exact status code for the rejection response.</param>
    /// <param name="rejectedHeaderPredicates">Optional rejection-header predicates keyed by header name.</param>
    /// <returns>A validated burst expectation.</returns>
    public static RateExpectation Burst(
        int acceptedRequestCount,
        Func<HttpResponseMessage, bool>? acceptedPredicate = null,
        Func<HttpResponseMessage, bool>? rejectedPredicate = null,
        int? rejectionStatusCode = null,
        IReadOnlyDictionary<string, Func<string?, bool>>? rejectedHeaderPredicates = null)
    {
        return Create(
            acceptedRequestCount,
            isUnlimited: false,
            acceptedPredicate,
            rejectedPredicate,
            rejectionStatusCode,
            rejectedHeaderPredicates);
    }

    /// <summary>Creates an expectation that every bounded request is accepted.</summary>
    /// <param name="requestCount">The number of requests to issue and validate.</param>
    /// <param name="acceptedPredicate">Optional predicate for accepted responses; defaults to any 2xx response.</param>
    /// <returns>A validated unlimited-endpoint expectation.</returns>
    public static RateExpectation Unlimited(
        int requestCount,
        Func<HttpResponseMessage, bool>? acceptedPredicate = null)
    {
        return Create(
            requestCount,
            isUnlimited: true,
            acceptedPredicate,
            rejectedPredicate: static _ => false,
            rejectionStatusCode: null,
            rejectedHeaderPredicates: null);
    }

    /// <summary>Creates a burst expectation whose accepted response must fall inside a status-code range.</summary>
    /// <param name="acceptedRequestCount">The number of requests expected to be accepted before rejection.</param>
    /// <param name="minimumStatusCode">The inclusive lower bound of the accepted status-code range.</param>
    /// <param name="maximumStatusCode">The inclusive upper bound of the accepted status-code range.</param>
    /// <param name="rejectionStatusCode">Optional exact status code for the rejection response.</param>
    /// <param name="rejectedHeaderPredicates">Optional rejection-header predicates keyed by header name.</param>
    /// <returns>A validated burst expectation.</returns>
    public static RateExpectation BurstWithSuccessStatusRange(
        int acceptedRequestCount,
        int minimumStatusCode,
        int maximumStatusCode,
        int? rejectionStatusCode = null,
        IReadOnlyDictionary<string, Func<string?, bool>>? rejectedHeaderPredicates = null)
    {
        ValidateStatusCode(minimumStatusCode, nameof(minimumStatusCode));
        ValidateStatusCode(maximumStatusCode, nameof(maximumStatusCode));
        if (minimumStatusCode > maximumStatusCode)
        {
            throw new ArgumentException("The minimum accepted status code cannot exceed the maximum.", nameof(minimumStatusCode));
        }

        if (rejectionStatusCode is not null && rejectionStatusCode >= minimumStatusCode && rejectionStatusCode <= maximumStatusCode)
        {
            throw new ArgumentException("The rejection status code cannot be inside the accepted status-code range.", nameof(rejectionStatusCode));
        }

        return Burst(
            acceptedRequestCount,
            response => (int)response.StatusCode >= minimumStatusCode && (int)response.StatusCode <= maximumStatusCode,
            rejectionStatusCode: rejectionStatusCode,
            rejectedHeaderPredicates: rejectedHeaderPredicates);
    }

    internal void Validate()
    {
        if (AcceptedRequestCount <= 0)
        {
            throw new InvalidOperationException("The expectation must issue at least one request.");
        }
    }

    private static RateExpectation Create(
        int requestCount,
        bool isUnlimited,
        Func<HttpResponseMessage, bool>? acceptedPredicate,
        Func<HttpResponseMessage, bool>? rejectedPredicate,
        int? rejectionStatusCode,
        IReadOnlyDictionary<string, Func<string?, bool>>? rejectedHeaderPredicates)
    {
        if (requestCount <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(requestCount), requestCount, "The request count must be greater than zero.");
        }

        if (requestCount > RateVerifier.HardMaximumRequestCount)
        {
            throw new ArgumentOutOfRangeException(nameof(requestCount), requestCount, $"The request count cannot exceed {RateVerifier.HardMaximumRequestCount}.");
        }

        if (rejectionStatusCode is not null)
        {
            ValidateStatusCode(rejectionStatusCode.Value, nameof(rejectionStatusCode));
        }

        var headers = new Dictionary<string, Func<string?, bool>>(StringComparer.OrdinalIgnoreCase);
        if (rejectedHeaderPredicates is not null)
        {
            foreach (var pair in rejectedHeaderPredicates)
            {
                if (string.IsNullOrWhiteSpace(pair.Key))
                {
                    throw new ArgumentException("Header predicate names cannot be empty.", nameof(rejectedHeaderPredicates));
                }

                ArgumentNullException.ThrowIfNull(pair.Value, nameof(rejectedHeaderPredicates));
                headers[pair.Key] = pair.Value;
            }
        }

        return new RateExpectation(
            requestCount,
            isUnlimited,
            acceptedPredicate ?? (static response => response.IsSuccessStatusCode),
            rejectedPredicate ?? (static response => !response.IsSuccessStatusCode),
            rejectionStatusCode,
            headers);
    }

    private static void ValidateStatusCode(int statusCode, string parameterName)
    {
        if (statusCode is < 100 or > 599)
        {
            throw new ArgumentOutOfRangeException(parameterName, statusCode, "The status code must be between 100 and 599.");
        }
    }
}
