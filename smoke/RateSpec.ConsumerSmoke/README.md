# Package Consumer Smoke

This non-packable project restores `KeelMatrix.RateSpec` from the built package in `artifacts/package` through `PackageReference`. It configures a real in-memory ASP.NET Core rate-limited endpoint, verifies two accepted requests followed by rejection, and verifies that partition B remains independent after partition A is exhausted.

Run it from the repository root after packing:

```powershell
$env:KEELMATRIX_NO_TELEMETRY = "1"
dotnet run --project smoke/RateSpec.ConsumerSmoke/RateSpec.ConsumerSmoke.csproj -c Release
```

