# RateSpec Development

This guide covers local validation for the `KeelMatrix.RateSpec` repository.

## Prerequisites

- .NET SDK 8.0.425 or a compatible 8.0 SDK patch
- Network access to `https://api.nuget.org/v3/index.json` for public package restore

## Validation

Run focused tests while changing behavior:

```powershell
$env:KEELMATRIX_NO_TELEMETRY = "1"
dotnet test tests/KeelMatrix.RateSpec.Tests/KeelMatrix.RateSpec.Tests.csproj -c Release --no-restore
```

The full local gate is:

```powershell
$env:KEELMATRIX_NO_TELEMETRY = "1"
dotnet restore tests/KeelMatrix.RateSpec.Tests/KeelMatrix.RateSpec.Tests.csproj --configfile NuGet.config --packages artifacts/test-packages
dotnet build tests/KeelMatrix.RateSpec.Tests/KeelMatrix.RateSpec.Tests.csproj -c Release --no-restore
dotnet test tests/KeelMatrix.RateSpec.Tests/KeelMatrix.RateSpec.Tests.csproj -c Release --no-build --no-restore
dotnet format src/KeelMatrix.RateSpec/KeelMatrix.RateSpec.csproj --verify-no-changes --no-restore
dotnet format tests/KeelMatrix.RateSpec.Tests/KeelMatrix.RateSpec.Tests.csproj --verify-no-changes --no-restore
dotnet restore src/KeelMatrix.RateSpec/KeelMatrix.RateSpec.csproj --configfile NuGet.config --packages artifacts/package-packages
dotnet pack src/KeelMatrix.RateSpec/KeelMatrix.RateSpec.csproj -c Release --no-restore -o artifacts/package

$package = Get-ChildItem artifacts/package -Filter "KeelMatrix.RateSpec.*.nupkg" | Where-Object Name -notlike "*.snupkg"
$symbols = Get-ChildItem artifacts/package -Filter "KeelMatrix.RateSpec.*.snupkg"
pwsh ./scripts/Validate-PackageArchive.ps1 -PackagePath $package.FullName -SymbolPackagePath $symbols.FullName -AllowMissingIcon
pwsh ./tests/Validate-PackageArchive.Tests.ps1 -PackagePath $package.FullName -SymbolPackagePath $symbols.FullName
pwsh ./scripts/Verify-CommitMessages.ps1 -SelfTest
```

The package-consumer smoke test is a separate phase because the solution includes the consumer before the local package
exists. It uses `PackageReference` to the produced package from an isolated local feed:

```powershell
$smokePackages = Join-Path $env:TEMP "ratespec-smoke-packages-$([Guid]::NewGuid().ToString('N'))"
dotnet restore smoke/RateSpec.ConsumerSmoke/RateSpec.ConsumerSmoke.csproj --configfile smoke/NuGet.config --packages $smokePackages --no-cache --force
pwsh ./scripts/Validate-PackageRestore.ps1 -PackagePath $package.FullName -AssetsFile smoke/RateSpec.ConsumerSmoke/obj/project.assets.json
dotnet build smoke/RateSpec.ConsumerSmoke/RateSpec.ConsumerSmoke.csproj -c Release --no-restore
dotnet run --project smoke/RateSpec.ConsumerSmoke/RateSpec.ConsumerSmoke.csproj -c Release --no-build --no-restore
```

The smoke setup creates a fresh restore folder and package source mapping, forces a new resolution, and compares the
consumer assets-file SHA-512 value with the produced archive. A stale same-version package therefore fails the gate
instead of silently passing. It does not use a project reference to the shipping library.

The tag-triggered release workflow runs `pwsh ./scripts/Validate-Release.ps1 -Tag vX.Y.Z` before building or publishing. That
check requires the tag, package version, and a dated, finalized changelog entry to agree. The release job then validates the
exact `.nupkg` and `.snupkg` set before using NuGet Trusted Publishing.

## CI package gate

CI runs the Release tests and formatting checks on Ubuntu, Windows, and macOS, then builds the package and symbol package,
inspects both archives, audits dependencies, and runs the package-consumer smoke test from the generated `.nupkg`.

The archive check calls `Validate-PackageArchive.ps1 -AllowMissingIcon` before the manually supplied repository icon is present.
That explicit pre-release allowance keeps the candidate verifiable without treating a missing `icon.png` as release-ready.
When `icon.png` is present, the same check requires a 512×512 PNG no larger than 200 KB, `icon.png` package metadata,
and byte-identical package contents. The archive check also uses an exact allowlist for package and symbol entries.
