#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('All', 'Test', 'Package')]
    [string] $Phase = 'All',
    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../build/Invoke-NestedPwsh.ps1')

function Invoke-Checked {
    param([string] $Command, [object[]] $Arguments)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $global:LASTEXITCODE = 0
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE. Validation stopped." }
    Write-Host ("PASS {0} {1} ({2:n2}s)" -f $Command, ($Arguments -join ' '), $timer.Elapsed.TotalSeconds)
}

$previousTelemetry = $env:KEELMATRIX_NO_TELEMETRY
$previousCliTelemetry = $env:DOTNET_CLI_TELEMETRY_OPTOUT
$temporaryRoot = $null
Push-Location $RepositoryRoot
try {
    $env:KEELMATRIX_NO_TELEMETRY = '1'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $tests = 'tests/KeelMatrix.RateSpec.Tests/KeelMatrix.RateSpec.Tests.csproj'
    $shipping = 'src/KeelMatrix.RateSpec/KeelMatrix.RateSpec.csproj'
    Invoke-Checked Invoke-NestedPwsh @('-NoProfile', '-File', './scripts/Validate-WebsiteMetadata.ps1')
    if ($Phase -in @('All', 'Test')) {
        Invoke-Checked dotnet @('restore', $tests, '--configfile', 'NuGet.config', '--packages', 'artifacts/test-packages')
        Invoke-Checked dotnet @('build', $tests, '-c', 'Release', '--no-restore')
        Invoke-Checked dotnet @('test', $tests, '-c', 'Release', '--no-build', '--no-restore')
        foreach ($project in @($shipping, $tests)) {
            Invoke-Checked dotnet @('format', $project, '--verify-no-changes', '--no-restore')
        }
        Invoke-Checked Invoke-NestedPwsh @('-NoProfile', '-File', './scripts/Verify-CommitMessages.ps1', '-SelfTest')
        Invoke-Checked Invoke-NestedPwsh @('-NoProfile', '-File', './build/Test-NestedPwshLaunch.ps1', '-SelfTest')
        Invoke-Checked Invoke-NestedPwsh @('-NoProfile', '-File', './build/Test-NestedPwshLaunch.ps1')
        foreach ($suite in @('Read-BigEndianUInt32', 'Workflow-FailurePropagation', 'Validate-Local', 'Validate-RepositoryIgnore',
                'Validate-Release', 'Validate-TextHygiene', 'Validate-PackageRestore', 'Validate-VulnerabilityAudit', 'Validate-WebsiteMetadata')) {
            Invoke-Checked Invoke-NestedPwsh @('-NoProfile', '-File', "./tests/$suite.Tests.ps1")
        }
    }
    if ($Phase -in @('All', 'Package')) {
        Invoke-Checked dotnet @('restore', $shipping, '--configfile', 'NuGet.config', '--packages', 'artifacts/package-packages')
        Invoke-Checked dotnet @('pack', $shipping, '-c', 'Release', '--no-restore', '-o', 'artifacts/package')
        $props = [xml](Get-Content -Raw 'Directory.Build.props')
        $versionNodes = @($props.SelectNodes('/Project/PropertyGroup/Version'))
        if ($versionNodes.Count -ne 1) { throw 'Expected one explicit package Version in Directory.Build.props.' }
        $version = $versionNodes[0].InnerText.Trim()
        if ($version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') { throw 'Expected a stable X.Y.Z package Version.' }
        $package = "artifacts/package/KeelMatrix.RateSpec.$version.nupkg"
        $symbols = "artifacts/package/KeelMatrix.RateSpec.$version.snupkg"
        $expected = @([IO.Path]::GetFileName($package), [IO.Path]::GetFileName($symbols))
        $files = @(Get-ChildItem -LiteralPath artifacts/package -File)
        if ($files.Count -ne 2 -or @($files | Where-Object Name -cnotin $expected).Count -ne 0) {
            throw "Expected exactly $($expected -join ' and ')."
        }
        Invoke-Checked Invoke-NestedPwsh @('-NoProfile', '-File', './scripts/Validate-WebsiteMetadata.ps1', '-PackagePath', $package, '-SymbolPackagePath', $symbols)
        Invoke-Checked Invoke-NestedPwsh @('-NoProfile', '-File', './scripts/Validate-PackageArchive.ps1', '-PackagePath', $package, '-SymbolPackagePath', $symbols)
        Invoke-Checked Invoke-NestedPwsh @('-NoProfile', '-File', './tests/Validate-PackageArchive.Tests.ps1', '-PackagePath', $package, '-SymbolPackagePath', $symbols)
        $audit = @(Invoke-Checked dotnet @('list', $shipping, 'package', '--vulnerable', '--include-transitive', '--format', 'json', '--output-version', '1', '--configfile', 'NuGet.config'))
        $auditText = $audit | Out-String
        Write-Output $auditText
        Invoke-Checked Invoke-NestedPwsh @('-NoProfile', '-File', './scripts/Validate-VulnerabilityAudit.ps1', '-ReportJson', $auditText)

        $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "ratespec-consumer-$([Guid]::NewGuid().ToString('N'))"
        $consumer = 'smoke/RateSpec.ConsumerSmoke/RateSpec.ConsumerSmoke.csproj'
        Invoke-Checked dotnet @('restore', $consumer, '--configfile', 'smoke/NuGet.config', '--packages', $temporaryRoot, '--no-cache', '--force')
        Invoke-Checked Invoke-NestedPwsh @('-NoProfile', '-File', './scripts/Validate-PackageRestore.ps1', '-PackagePath', $package, '-AssetsFile', 'smoke/RateSpec.ConsumerSmoke/obj/project.assets.json')
        Invoke-Checked dotnet @('build', $consumer, '-c', 'Release', '--no-restore')
        Invoke-Checked dotnet @('run', '--project', $consumer, '-c', 'Release', '--no-build', '--no-restore')
    }
    Write-Output "Local validation passed ($Phase)."
}
finally {
    $env:KEELMATRIX_NO_TELEMETRY = $previousTelemetry
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = $previousCliTelemetry
    Pop-Location
    if ($temporaryRoot -and (Test-Path -LiteralPath $temporaryRoot)) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolved) -notlike 'ratespec-consumer-*') { throw 'Unsafe temporary cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
