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

