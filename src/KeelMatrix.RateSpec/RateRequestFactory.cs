namespace KeelMatrix.RateSpec;

/// <summary>Creates one request for a bounded verification step.</summary>
/// <param name="requestNumber">The zero-based request number within the scenario.</param>
/// <returns>A new request message owned by the verifier for the duration of the send.</returns>
public delegate HttpRequestMessage RateRequestFactory(int requestNumber);

