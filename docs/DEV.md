# RateSpec Development

This guide covers local validation for the `KeelMatrix.RateSpec` repository.

## Prerequisites

- PowerShell 7 (`pwsh`) on Windows, Linux, or macOS
- .NET SDK 8.0.425 or a compatible 8.0 SDK patch selected by `global.json`
- Git with complete, non-shallow repository history
- Network access to `https://api.nuget.org/v3/index.json` for public restore and vulnerability data

## Validation

From the repository root, run the canonical full local gate:

```powershell
pwsh -NoProfile -File ./scripts/Validate-Local.ps1
```

The script stops on the first failed native command, disables telemetry for its execution, and reports command durations.
It restores/builds/tests the library and tests in Release, verifies formatting, runs repository and validator regressions,
packs the exact artifact pair, validates both archives, performs a real direct/transitive vulnerability audit, and
restores/builds/runs the isolated package consumer. Both CI and the tag-triggered release workflow use this entry point.
CI exercises the full gate on Windows, Linux, and macOS. No validation command publishes anything.

For focused work, use the relevant phase; these are partial gates:

```powershell
pwsh -NoProfile -File ./scripts/Validate-Local.ps1 -Phase Test
```

```powershell
pwsh -NoProfile -File ./scripts/Validate-Local.ps1 -Phase Package
```

For one behavior test, set `KEELMATRIX_NO_TELEMETRY=1` and run `dotnet test` with the appropriate filter.
`Test` restores/builds/tests and checks formatting and repository guards. `Package` restores the shipping project,
packs and validates both artifacts, audits dependencies, and runs the consumer. `All` (the default) performs both phases.
A final full gate is required after focused changes settle.

## Package and consumer checks

The exact artifact set in `artifacts/package` is `KeelMatrix.RateSpec.<version>.nupkg` and
`KeelMatrix.RateSpec.<version>.snupkg`, using `Directory.Build.props`. Unexpected files fail validation.
`scripts/Validate-PackageArchive.ps1` owns the archive contract: unique entries, required ZIP structure and nuspec in
both artifacts, matching ID/version, exact `net8.0` dependency on Telemetry 0.1.1 and framework reference to
`Microsoft.AspNetCore.App`, symbol package type and PDB, plus package README/license/icon metadata and content.
The symbol archive is validated before publication can start. Mutation tests exercise both manifests and dependency graphs.

The full gate requires the repository-root `icon.png` and its package-root entry: a 512x512 PNG no larger than 200 KB,
with byte-identical source/package content. Icon checks read existing bytes only. The archive validator's explicit
`-AllowMissingIcon` option is for incomplete development fixtures and does not satisfy the full gate.

The consumer uses `PackageReference`, controlled sources and package source mapping in `smoke/NuGet.config`.
Each run uses a fresh package cache under `[IO.Path]::GetTempPath()`, with forced uncached resolution. The restore identity
validator compares the consumer assets-file SHA-512 against the exact produced archive before the consumer builds/runs.
The temporary package cache is removed afterward; run the phase again to restore a fresh consumer. No sibling source
repository or hidden local feed is needed. See the [consumer smoke guide](../smoke/RateSpec.ConsumerSmoke/README.md).

## Release metadata and failure propagation

`scripts/Validate-Release.ps1` owns structural release validation. It requires tag/package/version alignment and one
unique, real, dated target heading in `CHANGELOG.md`, separate from `## [Unreleased]`. Supported release headings are
unindented `## [X.Y.Z] - YYYY-MM-DD`; draft entries can use `Planned` during development but fail release validation.
Release categories are ATX headings; the first release has exactly one `Added` category. Ambiguous target heading
representations (including other depths, indentation, closing hashes and Setext headings) fail closed. Backtick/tilde
fenced code and HTML comments do not declare release sections; unterminated fences/comments fail validation. Duplicate
target versions and draft-state/transition markers fail. Adjacent versions have separate content. Structural success
still requires human editorial review before release authorization.

`scripts/Verify-CommitMessages.ps1` scans complete reachable subject/body text and rejects attribution trailers,
restricted wording and private numeric work-item references. Its self-test includes valid lookalikes, subject/body
variants, secondary refs and shallow-history rejection. Integer-decoding tests cover unsigned boundaries without
creating image assets. IDE checks include nested ASP.NET Core launch settings with a missing-pattern negative control.

`tests/Validate-Local.Tests.ps1` executes the canonical entry point with inert command substitutes, checking success,
TEMP-absent portable paths, and immediate failure at every native-command position. Workflow failure tests execute
actual release archive/publication bodies with inert substitutes. A bad artifact stops before NuGet login or push;
the primary push uses `--no-symbols` and symbols have one explicit subsequent push. Tests do not publish packages.
