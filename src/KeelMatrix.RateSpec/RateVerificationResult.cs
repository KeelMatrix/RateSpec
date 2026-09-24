namespace KeelMatrix.RateSpec;

/// <summary>Classifies a verification verdict without including request or response content.</summary>
public enum RateVerificationFailureKind
{
    /// <summary>The verification completed successfully.</summary>
    None,

    /// <summary>A request was rejected before the expected rejection step.</summary>
    EarlyRejection,

    /// <summary>The expected rejection was not observed.</summary>
    MissingRejection,

    /// <summary>A supposedly independent partition was affected by another partition.</summary>
    PartitionLeakage,

    /// <summary>A supposedly shared partition did not share its consumed budget.</summary>
    ExpectedSharingNotObserved,

    /// <summary>An endpoint expected to be unlimited rejected a request.</summary>
    UnexpectedLimit,

    /// <summary>A response predicate or exact status expectation did not match.</summary>
    StatusMismatch,

    /// <summary>A response-header predicate did not match.</summary>
    HeaderMismatch,

    /// <summary>The request safety ceiling would have been exceeded.</summary>
    SafetyCeilingExceeded,

    /// <summary>Verification was cancelled by the caller.</summary>
    Cancelled,

    /// <summary>The request factory or HTTP host failed without exposing its exception details.</summary>
    HostFailure
}

/// <summary>Records one request outcome without retaining response content.</summary>
public sealed class RateResponseObservation
{
    internal RateResponseObservation(int requestNumber, int? statusCode, bool predicateMatched)
    {
        RequestNumber = requestNumber;
        StatusCode = statusCode;
        PredicateMatched = predicateMatched;
    }

    /// <summary>Gets the zero-based request number within the scenario.</summary>
    public int RequestNumber { get; }

    /// <summary>Gets the observed status code, when a response was received.</summary>
    public int? StatusCode { get; }

    /// <summary>Gets a value indicating whether the expected response contract matched.</summary>
    public bool PredicateMatched { get; }
}

/// <summary>Contains the verdict for one scenario.</summary>
public sealed class RateScenarioResult
{
    internal RateScenarioResult(
        bool succeeded,
        int requestsIssued,
        RateVerificationFailureKind failureKind,
        string message,
        IReadOnlyList<RateResponseObservation> observations)
    {
        Succeeded = succeeded;
        RequestsIssued = requestsIssued;
        FailureKind = failureKind;
        Message = message;
        Observations = observations;
    }

    /// <summary>Gets a value indicating whether the scenario passed.</summary>
    public bool Succeeded { get; }

    /// <summary>Gets the number of requests issued by the scenario.</summary>
    public int RequestsIssued { get; }

    /// <summary>Gets the failure classification, or <see cref="RateVerificationFailureKind.None"/>.</summary>
    public RateVerificationFailureKind FailureKind { get; }

    /// <summary>Gets a safe, content-free explanation of the verdict.</summary>
    public string Message { get; }

    /// <summary>Gets request-by-request status observations without headers or bodies.</summary>
    public IReadOnlyList<RateResponseObservation> Observations { get; }
}

/// <summary>Contains the aggregate result of a rate contract verification.</summary>
public sealed class RateVerificationResult
{
    internal RateVerificationResult(
        bool succeeded,
        int requestsIssued,
        RateVerificationFailureKind failureKind,
        string message,
        IReadOnlyList<RateScenarioResult> scenarios)
    {
        Succeeded = succeeded;
        RequestsIssued = requestsIssued;
        FailureKind = failureKind;
        Message = message;
        Scenarios = scenarios;
    }

    /// <summary>Gets a value indicating whether every executed scenario passed.</summary>
    public bool Succeeded { get; }

    /// <summary>Gets the total number of requests issued.</summary>
    public int RequestsIssued { get; }

    /// <summary>Gets the aggregate failure classification, or <see cref="RateVerificationFailureKind.None"/>.</summary>
    public RateVerificationFailureKind FailureKind { get; }

    /// <summary>Gets a safe, content-free explanation of the aggregate verdict.</summary>
    public string Message { get; }

    /// <summary>Gets the results for scenarios reached before the verdict.</summary>
    public IReadOnlyList<RateScenarioResult> Scenarios { get; }
}

