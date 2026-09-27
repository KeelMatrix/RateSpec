using KeelMatrix.Telemetry;

namespace KeelMatrix.RateSpec;

/// <summary>Executes bounded, sequential HTTP behavior checks against a caller-owned test host.</summary>
public sealed class RateVerifier
{
    private readonly Action _activationTracker;

    /// <summary>The default per-contract request ceiling.</summary>
    public const int DefaultMaximumRequestCount = 100;

    /// <summary>The absolute request ceiling accepted by a verifier.</summary>
    public const int HardMaximumRequestCount = 1000;

    /// <summary>Creates a verifier with a bounded request ceiling.</summary>
    /// <param name="maximumRequestCount">The maximum number of requests one contract may issue.</param>
    public RateVerifier(int maximumRequestCount = DefaultMaximumRequestCount)
        : this(maximumRequestCount, TrackActivation)
    {
    }

    internal RateVerifier(int maximumRequestCount, Action activationTracker)
    {
        if (maximumRequestCount <= 0 || maximumRequestCount > HardMaximumRequestCount)
        {
            throw new ArgumentOutOfRangeException(
                nameof(maximumRequestCount),
                maximumRequestCount,
                $"The maximum request count must be between 1 and {HardMaximumRequestCount}.");
        }

        ArgumentNullException.ThrowIfNull(activationTracker);
        MaximumRequestCount = maximumRequestCount;
        _activationTracker = activationTracker;
    }

    /// <summary>Gets the maximum number of requests this verifier may issue for one contract.</summary>
    public int MaximumRequestCount { get; }

    /// <summary>Verifies the contract sequentially and returns a content-free structured verdict.</summary>
    /// <param name="contract">The caller-owned client and bounded scenarios.</param>
    /// <param name="cancellationToken">Cancels verification and the in-flight HTTP operation. An HTTP cancellation that does not cancel this token is reported as <see cref="RateVerificationFailureKind.HostFailure"/>.</param>
    /// <returns>The aggregate verification result.</returns>
    public Task<RateVerificationResult> VerifyAsync(
        RateContract contract,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(contract);

        int expectedRequestCount;
        try
        {
            expectedRequestCount = contract.Scenarios.Sum(static scenario => scenario.ExpectedRequestCount);
        }
        catch (OverflowException)
        {
            return Task.FromResult(CreateFailure(
                0,
                RateVerificationFailureKind.SafetyCeilingExceeded,
                "The contract exceeds the request safety ceiling."));
        }

        if (expectedRequestCount > MaximumRequestCount)
        {
            return Task.FromResult(CreateFailure(
                0,
                RateVerificationFailureKind.SafetyCeilingExceeded,
                "The contract exceeds the request safety ceiling."));
        }

        if (cancellationToken.IsCancellationRequested)
        {
            return Task.FromResult(CreateFailure(0, RateVerificationFailureKind.Cancelled, "Verification was cancelled."));
        }

        return VerifyCoreAsync(contract, cancellationToken);
    }

    private async Task<RateVerificationResult> VerifyCoreAsync(
        RateContract contract,
        CancellationToken cancellationToken)
    {
        var scenarioResults = new List<RateScenarioResult>(contract.Scenarios.Count);
        var requestCount = 0;

        foreach (var scenario in contract.Scenarios)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                return CompleteResult(CreateAggregateResult(
                    succeeded: false,
                    requestCount,
                    RateVerificationFailureKind.Cancelled,
                    "Verification was cancelled.",
                    scenarioResults));
            }

            var scenarioResult = await RunScenarioAsync(contract.Client, scenario, cancellationToken).ConfigureAwait(false);
            scenarioResults.Add(scenarioResult);
            requestCount += scenarioResult.RequestsIssued;

            if (cancellationToken.IsCancellationRequested)
            {
                return CompleteResult(CreateAggregateResult(
                    succeeded: false,
                    requestCount,
                    RateVerificationFailureKind.Cancelled,
                    "Verification was cancelled.",
                    scenarioResults));
            }

            if (!scenarioResult.Succeeded)
            {
                return CompleteResult(CreateAggregateResult(
                    succeeded: false,
                    requestCount,
                    scenarioResult.FailureKind,
                    scenarioResult.Message,
                    scenarioResults));
            }
        }

        return CompleteResult(CreateAggregateResult(
            succeeded: true,
            requestCount,
            RateVerificationFailureKind.None,
            "The rate contract passed.",
            scenarioResults));
    }

    private static async Task<RateScenarioResult> RunScenarioAsync(
        HttpClient client,
        RateScenario scenario,
        CancellationToken cancellationToken)
    {
        var observations = new List<RateResponseObservation>();

        try
        {
            return scenario.Kind switch
            {
                RateScenarioKind.InitialBurst => await RunBurstAsync(
                    client,
                    scenario.FirstRequestFactory,
                    scenario.Expectation,
                    observations,
                    firstRequestFailureKind: null,
                    cancellationToken: cancellationToken).ConfigureAwait(false),

                RateScenarioKind.Unlimited => await RunUnlimitedAsync(
                    client,
                    scenario.FirstRequestFactory,
                    scenario.Expectation,
                    observations,
                    cancellationToken).ConfigureAwait(false),

                RateScenarioKind.PartitionIsolation => await RunPartitionIsolationAsync(
                    client,
                    scenario,
                    observations,
                    cancellationToken).ConfigureAwait(false),

                RateScenarioKind.SharedPartition => await RunSharedPartitionAsync(
                    client,
                    scenario,
                    observations,
                    cancellationToken).ConfigureAwait(false),

                _ => CreateScenarioFailure(observations, RateVerificationFailureKind.HostFailure, "The scenario kind is not supported.")
            };
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return CreateScenarioFailure(observations, RateVerificationFailureKind.Cancelled, "Verification was cancelled.");
        }
        catch
        {
            return CreateScenarioFailure(observations, RateVerificationFailureKind.HostFailure, "The request factory or HTTP host failed.");
        }
    }

    private static async Task<RateScenarioResult> RunPartitionIsolationAsync(
        HttpClient client,
        RateScenario scenario,
        List<RateResponseObservation> observations,
        CancellationToken cancellationToken)
    {
        var first = await RunBurstAsync(
            client,
            scenario.FirstRequestFactory,
            scenario.Expectation,
            observations,
            firstRequestFailureKind: null,
            cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!first.Succeeded)
        {
            return first;
        }

        var second = await RunBurstAsync(
            client,
            scenario.SecondRequestFactory!,
            scenario.Expectation,
            observations,
            firstRequestFailureKind: RateVerificationFailureKind.PartitionLeakage,
            cancellationToken: cancellationToken).ConfigureAwait(false);
        if (second.FailureKind == RateVerificationFailureKind.PartitionLeakage)
        {
            return CreateScenarioFailure(
                observations,
                RateVerificationFailureKind.PartitionLeakage,
                "The second partition was rejected after the first partition consumed its burst.");
        }

        return second.Succeeded
            ? CreateScenarioSuccess(observations)
            : CreateScenarioFailure(observations, second.FailureKind, second.Message);
    }

    private static async Task<RateScenarioResult> RunSharedPartitionAsync(
        HttpClient client,
        RateScenario scenario,
        List<RateResponseObservation> observations,
        CancellationToken cancellationToken)
    {
        var first = await RunBurstAsync(
            client,
            scenario.FirstRequestFactory,
            scenario.Expectation,
            observations,
            firstRequestFailureKind: null,
            cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!first.Succeeded)
        {
            return first;
        }

        var evaluation = await EvaluateRequestAsync(
            client,
            scenario.SecondRequestFactory!,
            requestNumber: 0,
            expectation: scenario.Expectation,
            expectRejection: true,
            cancellationToken).ConfigureAwait(false);
        observations.Add(evaluation.Observation);

        return evaluation.FailureKind is null
            ? CreateScenarioSuccess(observations)
            : evaluation.FailureKind == RateVerificationFailureKind.Cancelled
                ? CreateScenarioFailure(observations, evaluation.FailureKind.Value, evaluation.Message)
                : evaluation.FailureKind == RateVerificationFailureKind.MissingRejection
                    ? CreateScenarioFailure(
                        observations,
                        RateVerificationFailureKind.ExpectedSharingNotObserved,
                        "The second request factory did not observe the consumed shared partition budget.")
                    : CreateScenarioFailure(observations, evaluation.FailureKind.Value, evaluation.Message);
    }

    private static async Task<RateScenarioResult> RunBurstAsync(
        HttpClient client,
        RateRequestFactory requestFactory,
        RateExpectation expectation,
        List<RateResponseObservation> observations,
        RateVerificationFailureKind? firstRequestFailureKind,
        CancellationToken cancellationToken)
    {
        for (var requestNumber = 0; requestNumber < expectation.AcceptedRequestCount; requestNumber++)
        {
            var evaluation = await EvaluateRequestAsync(
                client,
                requestFactory,
                requestNumber,
                expectation,
                expectRejection: false,
                cancellationToken).ConfigureAwait(false);
            observations.Add(evaluation.Observation);

            if (evaluation.FailureKind is not null)
            {
                if (requestNumber == 0 && firstRequestFailureKind is not null && evaluation.FailureKind == RateVerificationFailureKind.EarlyRejection)
                {
                    return CreateScenarioFailure(observations, firstRequestFailureKind.Value, "A supposedly independent partition was rejected before its own burst.");
                }

                return CreateScenarioFailure(observations, evaluation.FailureKind.Value, evaluation.Message);
            }
        }

        var rejection = await EvaluateRequestAsync(
            client,
            requestFactory,
            expectation.AcceptedRequestCount,
            expectation,
            expectRejection: true,
            cancellationToken).ConfigureAwait(false);
        observations.Add(rejection.Observation);
        return rejection.FailureKind is null
            ? CreateScenarioSuccess(observations)
            : CreateScenarioFailure(observations, rejection.FailureKind.Value, rejection.Message);
    }

    private static async Task<RateScenarioResult> RunUnlimitedAsync(
        HttpClient client,
        RateRequestFactory requestFactory,
        RateExpectation expectation,
        List<RateResponseObservation> observations,
        CancellationToken cancellationToken)
    {
        for (var requestNumber = 0; requestNumber < expectation.AcceptedRequestCount; requestNumber++)
        {
            var evaluation = await EvaluateRequestAsync(
                client,
                requestFactory,
                requestNumber,
                expectation,
                expectRejection: false,
                cancellationToken).ConfigureAwait(false);
            observations.Add(evaluation.Observation);

            if (evaluation.FailureKind is not null)
            {
                var failure = evaluation.FailureKind == RateVerificationFailureKind.EarlyRejection
                    ? RateVerificationFailureKind.UnexpectedLimit
                    : evaluation.FailureKind.Value;
                var message = failure == RateVerificationFailureKind.UnexpectedLimit
                    ? "An endpoint expected to be unlimited rejected a request."
                    : evaluation.Message;
                return CreateScenarioFailure(observations, failure, message);
            }
        }

        return CreateScenarioSuccess(observations);
    }

    private static async Task<RequestEvaluation> EvaluateRequestAsync(
        HttpClient client,
        RateRequestFactory requestFactory,
        int requestNumber,
        RateExpectation expectation,
        bool expectRejection,
        CancellationToken cancellationToken)
    {
        HttpRequestMessage? request = null;
        var requestWasIssued = false;
        try
        {
            try
            {
                cancellationToken.ThrowIfCancellationRequested();
                request = requestFactory(requestNumber) ?? throw new InvalidOperationException();
            }
            catch (OperationCanceledException)
            {
                return RequestEvaluation.Failure(
                    requestNumber,
                    statusCode: null,
                    RateVerificationFailureKind.Cancelled,
                    "Verification was cancelled.",
                    requestWasIssued);
            }
            catch
            {
                return RequestEvaluation.Failure(
                    requestNumber,
                    statusCode: null,
                    RateVerificationFailureKind.HostFailure,
                    "The request factory or HTTP host failed.",
                    requestWasIssued);
            }

            requestWasIssued = true;
            HttpResponseMessage response;
            try
            {
                response = await client.SendAsync(
                    request,
                    HttpCompletionOption.ResponseHeadersRead,
                    cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return RequestEvaluation.Failure(
                    requestNumber,
                    statusCode: null,
                    cancellationToken.IsCancellationRequested
                        ? RateVerificationFailureKind.Cancelled
                        : RateVerificationFailureKind.HostFailure,
                    cancellationToken.IsCancellationRequested
                        ? "Verification was cancelled."
                        : "The HTTP host cancelled the request without caller cancellation.",
                    requestWasIssued);
            }

            using (response)
            {
                var statusCode = (int)response.StatusCode;
                if (cancellationToken.IsCancellationRequested)
                {
                    return RequestEvaluation.Failure(
                        requestNumber,
                        statusCode,
                        RateVerificationFailureKind.Cancelled,
                        "Verification was cancelled.",
                        requestWasIssued);
                }

                var predicateMatched = false;
                try
                {
                    predicateMatched = expectRejection
                        ? expectation.RejectedPredicate(response)
                        : expectation.AcceptedPredicate(response);
                }
                catch
                {
                    return cancellationToken.IsCancellationRequested
                        ? RequestEvaluation.Failure(
                            requestNumber,
                            statusCode,
                            RateVerificationFailureKind.Cancelled,
                            "Verification was cancelled.",
                            requestWasIssued)
                        : RequestEvaluation.Failure(
                            requestNumber,
                            statusCode,
                            RateVerificationFailureKind.HostFailure,
                            "A response predicate failed without a usable verdict.",
                            requestWasIssued);
                }

                if (cancellationToken.IsCancellationRequested)
                {
                    return RequestEvaluation.Failure(
                        requestNumber,
                        statusCode,
                        RateVerificationFailureKind.Cancelled,
                        "Verification was cancelled.",
                        requestWasIssued);
                }

                if (!predicateMatched)
                {
                    var failure = expectRejection
                        ? response.IsSuccessStatusCode ? RateVerificationFailureKind.MissingRejection : RateVerificationFailureKind.StatusMismatch
                        : response.IsSuccessStatusCode ? RateVerificationFailureKind.StatusMismatch : RateVerificationFailureKind.EarlyRejection;
                    return RequestEvaluation.Failure(requestNumber, statusCode, failure, GetMessage(failure), requestWasIssued);
                }

                if (expectRejection)
                {
                    bool acceptedMatched;
                    try
                    {
                        acceptedMatched = expectation.AcceptedPredicate(response);
                    }
                    catch
                    {
                        return cancellationToken.IsCancellationRequested
                            ? RequestEvaluation.Failure(
                                requestNumber,
                                statusCode,
                                RateVerificationFailureKind.Cancelled,
                                "Verification was cancelled.",
                                requestWasIssued)
                            : RequestEvaluation.Failure(
                                requestNumber,
                                statusCode,
                                RateVerificationFailureKind.HostFailure,
                                "A response predicate failed without a usable verdict.",
                                requestWasIssued);
                    }

                    if (cancellationToken.IsCancellationRequested)
                    {
                        return RequestEvaluation.Failure(
                            requestNumber,
                            statusCode,
                            RateVerificationFailureKind.Cancelled,
                            "Verification was cancelled.",
                            requestWasIssued);
                    }

                    if (acceptedMatched)
                    {
                        return RequestEvaluation.Failure(
                            requestNumber,
                            statusCode,
                            RateVerificationFailureKind.StatusMismatch,
                            "The rejection response also matched the accepted predicate.",
                            requestWasIssued);
                    }

                    if (expectation.RejectionStatusCode is int expectedStatus && statusCode != expectedStatus)
                    {
                        return RequestEvaluation.Failure(
                            requestNumber,
                            statusCode,
                            RateVerificationFailureKind.StatusMismatch,
                            "The rejection status did not match the expectation.",
                            requestWasIssued);
                    }

                    foreach (var header in expectation.RejectedHeaderPredicates)
                    {
                        var value = GetHeaderValue(response, header.Key);
                        bool headerMatched;
                        try
                        {
                            headerMatched = header.Value(value);
                        }
                        catch
                        {
                            return cancellationToken.IsCancellationRequested
                                ? RequestEvaluation.Failure(
                                    requestNumber,
                                    statusCode,
                                    RateVerificationFailureKind.Cancelled,
                                    "Verification was cancelled.",
                                    requestWasIssued)
                                : RequestEvaluation.Failure(
                                    requestNumber,
                                    statusCode,
                                    RateVerificationFailureKind.HostFailure,
                                    "A response-header predicate failed without a usable verdict.",
                                    requestWasIssued);
                        }

                        if (cancellationToken.IsCancellationRequested)
                        {
                            return RequestEvaluation.Failure(
                                requestNumber,
                                statusCode,
                                RateVerificationFailureKind.Cancelled,
                                "Verification was cancelled.",
                                requestWasIssued);
                        }

                        if (!headerMatched)
                        {
                            return RequestEvaluation.Failure(
                                requestNumber,
                                statusCode,
                                RateVerificationFailureKind.HeaderMismatch,
                                "A rejection response-header predicate did not match.",
                                requestWasIssued);
                        }
                    }
                }

                return cancellationToken.IsCancellationRequested
                    ? RequestEvaluation.Failure(
                        requestNumber,
                        statusCode,
                        RateVerificationFailureKind.Cancelled,
                        "Verification was cancelled.",
                        requestWasIssued)
                    : RequestEvaluation.Success(requestNumber, statusCode, requestWasIssued);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return RequestEvaluation.Failure(
                requestNumber,
                statusCode: null,
                RateVerificationFailureKind.Cancelled,
                "Verification was cancelled.",
                requestWasIssued);
        }
        catch
        {
            return RequestEvaluation.Failure(
                requestNumber,
                statusCode: null,
                RateVerificationFailureKind.HostFailure,
                "The request factory or HTTP host failed.",
                requestWasIssued);
        }
        finally
        {
            request?.Dispose();
        }
    }

    private static string? GetHeaderValue(HttpResponseMessage response, string name)
    {
        if (response.Headers.TryGetValues(name, out var headers))
        {
            return string.Join(", ", headers);
        }

        return response.Content.Headers.TryGetValues(name, out var contentHeaders)
            ? string.Join(", ", contentHeaders)
            : null;
    }

    private RateVerificationResult CompleteResult(RateVerificationResult result)
    {
        if (result.Scenarios.Any(static scenario => scenario.Observations.Any(static observation => observation.RequestWasIssued)))
        {
            TryTrackActivation();
        }

        return result;
    }

    private void TryTrackActivation()
    {
        try
        {
            _activationTracker();
        }
        catch
        {
            // Telemetry is best effort and must never alter a verification verdict.
        }
    }

    private static void TrackActivation() => new Client("RateSpec", typeof(RateVerifier)).TrackActivation();

    private static string GetMessage(RateVerificationFailureKind failureKind) => failureKind switch
    {
        RateVerificationFailureKind.EarlyRejection => "A request was rejected before the expected rejection step.",
        RateVerificationFailureKind.MissingRejection => "The expected rejection was not observed.",
        RateVerificationFailureKind.StatusMismatch => "A response status did not match the expectation.",
        _ => "The rate contract did not match the observed HTTP behavior."
    };

    private static RateVerificationResult CreateFailure(
        int requestsIssued,
        RateVerificationFailureKind failureKind,
        string message) => CreateAggregateResult(
        succeeded: false,
        requestsIssued,
        failureKind,
        message,
        Array.Empty<RateScenarioResult>());

    private static RateVerificationResult CreateAggregateResult(
        bool succeeded,
        int requestsIssued,
        RateVerificationFailureKind failureKind,
        string message,
        IReadOnlyList<RateScenarioResult> scenarios) => new(
        succeeded,
        requestsIssued,
        failureKind,
        message,
        scenarios);

    private static RateScenarioResult CreateScenarioSuccess(List<RateResponseObservation> observations) => new(
        succeeded: true,
        CountIssuedRequests(observations),
        RateVerificationFailureKind.None,
        "The scenario passed.",
        observations.ToArray());

    private static RateScenarioResult CreateScenarioFailure(
        List<RateResponseObservation> observations,
        RateVerificationFailureKind failureKind,
        string message) => new(
        succeeded: false,
        CountIssuedRequests(observations),
        failureKind,
        message,
        observations.ToArray());

    private static int CountIssuedRequests(IEnumerable<RateResponseObservation> observations) =>
        observations.Count(static observation => observation.RequestWasIssued);

    private sealed class RequestEvaluation
    {
        private RequestEvaluation(
            RateResponseObservation observation,
            RateVerificationFailureKind? failureKind,
            string message)
        {
            Observation = observation;
            FailureKind = failureKind;
            Message = message;
        }

        internal RateResponseObservation Observation { get; }

        internal RateVerificationFailureKind? FailureKind { get; }

        internal string Message { get; }

        internal static RequestEvaluation Success(int requestNumber, int statusCode, bool requestWasIssued) => new(
            new RateResponseObservation(requestNumber, statusCode, predicateMatched: true, requestWasIssued),
            failureKind: null,
            "");

        internal static RequestEvaluation Failure(
            int requestNumber,
            int? statusCode,
            RateVerificationFailureKind failureKind,
            string message,
            bool requestWasIssued) => new(
            new RateResponseObservation(requestNumber, statusCode, predicateMatched: false, requestWasIssued),
            failureKind,
            message);
    }
}
