# Package Consumer Smoke

This non-packable project restores `KeelMatrix.RateSpec` from the built package in `artifacts/package` through `PackageReference`. It configures a real in-memory ASP.NET Core rate-limited endpoint, verifies two accepted requests followed by rejection, and verifies that partition B remains independent after partition A is exhausted.

Run it from the repository root after packing:

```powershell
$env:KEELMATRIX_NO_TELEMETRY = "1"
$smokePackages = Join-Path $env:TEMP "ratespec-smoke-packages-$([Guid]::NewGuid().ToString('N'))"
dotnet restore smoke/RateSpec.ConsumerSmoke/RateSpec.ConsumerSmoke.csproj --configfile smoke/NuGet.config --packages $smokePackages --no-cache --force
pwsh ./scripts/Validate-PackageRestore.ps1 -PackagePath (Get-ChildItem artifacts/package -Filter "KeelMatrix.RateSpec.*.nupkg" | Where-Object Name -notlike "*.snupkg").FullName -AssetsFile smoke/RateSpec.ConsumerSmoke/obj/project.assets.json
dotnet build smoke/RateSpec.ConsumerSmoke/RateSpec.ConsumerSmoke.csproj -c Release --no-restore
dotnet run --project smoke/RateSpec.ConsumerSmoke/RateSpec.ConsumerSmoke.csproj -c Release --no-build --no-restore
```

The restore uses the isolated `smoke/NuGet.config` feed, which resolves the locally built package from
`artifacts/package`, and a fresh, unique package cache. The hash check proves that the assets file resolved the exact
archive being tested, so a stale same-version package is rejected. The smoke project uses `PackageReference` to the
package; it does not reference the shipping project directly.
