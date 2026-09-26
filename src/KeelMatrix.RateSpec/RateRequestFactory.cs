namespace KeelMatrix.RateSpec;

/// <summary>Creates one request for a bounded verification step.</summary>
/// <param name="requestNumber">The zero-based request number within this factory's request sequence. Each factory sequence starts at zero, including the second factory in a partition scenario.</param>
/// <returns>A new request message owned by the verifier for the duration of the send.</returns>
public delegate HttpRequestMessage RateRequestFactory(int requestNumber);
