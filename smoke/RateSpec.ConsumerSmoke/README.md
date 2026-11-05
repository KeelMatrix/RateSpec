# RateSpec Package Consumer Smoke

This project verifies the built `KeelMatrix.RateSpec` package through `PackageReference` and an in-memory test host.
It does not reference the shipping project.

Install PowerShell 7 and the .NET 8 SDK, then run from the repository root:

```powershell
pwsh -NoProfile -File ./scripts/Validate-Local.ps1 -Phase Package
```

This fail-fast phase packs and inspects the artifact pair, performs the real direct/transitive vulnerability audit,
then restores the consumer into a fresh portable temporary package cache. `smoke/NuGet.config` controls the local
artifact feed, public dependency feed and source mapping. The SHA-512 identity check proves the consumer resolved
the exact archive just built before building/running the smoke. Telemetry is disabled and the temporary cache is
removed after validation. The complete repository gate and prerequisites are in [Development](../../docs/DEV.md).
