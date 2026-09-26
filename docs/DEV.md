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
dotnet restore KeelMatrix.RateSpec.sln --configfile NuGet.config
dotnet build KeelMatrix.RateSpec.sln -c Release --no-restore
dotnet test KeelMatrix.RateSpec.sln -c Release --no-build
dotnet format KeelMatrix.RateSpec.sln --verify-no-changes
dotnet pack src/KeelMatrix.RateSpec/KeelMatrix.RateSpec.csproj -c Release --no-build -o artifacts/package
```

The package-consumer smoke test uses `PackageReference` to the produced package from an isolated local feed:

```powershell
dotnet run --project smoke/RateSpec.ConsumerSmoke/RateSpec.ConsumerSmoke.csproj -c Release
```

The smoke setup creates its own isolated restore folder and package source mapping. It does not use a project reference to the shipping library.

## CI package gate

CI runs the Release tests and formatting checks on Ubuntu, Windows, and macOS, then builds the package and symbol package,
inspects both archives, audits dependencies, and runs the package-consumer smoke test from the generated `.nupkg`.

The archive check calls `Test-PackageArchive -AllowMissingIcon` before the manually supplied repository icon is present.
That explicit pre-release allowance keeps the candidate verifiable without treating a missing `icon.png` as release-ready.
When `icon.png` is present, the same check requires a 512×512 PNG no larger than 200 KB, `icon.png` package metadata,
and byte-identical package contents.
