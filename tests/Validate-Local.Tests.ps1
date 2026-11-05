$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$validator = Join-Path $repositoryRoot 'scripts/Validate-Local.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "ratespec-local-$([Guid]::NewGuid().ToString('N'))"
$oldTemp = $env:TEMP
$oldExitCode = $global:LASTEXITCODE
$oldTelemetry = $env:KEELMATRIX_NO_TELEMETRY
$oldCliTelemetry = $env:DOTNET_CLI_TELEMETRY_OPTOUT
$localValidationState = [pscustomobject]@{ Calls = [Collections.Generic.List[string]]::new(); FailAt = 0 }

function Invoke-Stub {
    if ($env:KEELMATRIX_NO_TELEMETRY -ne '1' -or $env:DOTNET_CLI_TELEMETRY_OPTOUT -ne '1') {
        throw 'Validation must suppress telemetry for every native command.'
    }
    $localValidationState.Calls.Add(($args -join ' '))
    $global:LASTEXITCODE = if ($localValidationState.Calls.Count -eq $localValidationState.FailAt) { 23 } else { 0 }
}
function dotnet {
    Invoke-Stub @args
    if ($args[0] -eq 'list') { '{"version":1,"projects":[{"path":"shipping"}]}' }
}
function pwsh { Invoke-Stub @args }

New-Item -ItemType Directory -Path (Join-Path $testRoot 'artifacts/package') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $testRoot 'Directory.Build.props'), '<Project><PropertyGroup><Version> 0.1.0 </Version></PropertyGroup><PropertyGroup><Other>value</Other></PropertyGroup><PropertyGroup /></Project>')
foreach ($extension in @('nupkg', 'snupkg')) {
    [IO.File]::WriteAllText((Join-Path $testRoot "artifacts/package/KeelMatrix.RateSpec.0.1.0.$extension"), '')
}
try {
    # Unix does not require TEMP. Exercise the real entry point without it on every OS.
    $env:TEMP = $null
    $env:KEELMATRIX_NO_TELEMETRY = '0'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '0'
    $localValidationState.FailAt = 0
    $localValidationState.Calls = [Collections.Generic.List[string]]::new()
    & $validator -RepositoryRoot $testRoot -Phase All 6>&1 | Out-Null
    if ($env:KEELMATRIX_NO_TELEMETRY -ne '0' -or $env:DOTNET_CLI_TELEMETRY_OPTOUT -ne '0') { throw 'Validation did not restore caller telemetry settings.' }
    $commands = $localValidationState.Calls.ToArray()
    if (-not ($commands | Where-Object { $_ -match '^list .*--vulnerable --include-transitive' })) { throw 'Missing actual transitive vulnerability audit.' }
    if (-not ($commands | Where-Object { $_ -match '^restore smoke/.*--no-cache --force' })) { throw 'Missing isolated consumer restore.' }
    if (-not ($commands | Where-Object { $_ -match 'Validate-PackageRestore.ps1' })) { throw 'Missing exact-package consumer validation.' }
    foreach ($failurePosition in 1..$commands.Count) {
        $localValidationState.FailAt = $failurePosition
        $localValidationState.Calls = [Collections.Generic.List[string]]::new()
        $failed = $false
        try { & $validator -RepositoryRoot $testRoot -Phase All 6>&1 | Out-Null }
        catch { $failed = $true }
        if (-not $failed -or $localValidationState.Calls.Count -ne $localValidationState.FailAt) {
            throw "Local validation continued after native failure at $localValidationState.FailAt (calls=$($localValidationState.Calls.Count))."
        }
        if ($env:KEELMATRIX_NO_TELEMETRY -ne '0' -or $env:DOTNET_CLI_TELEMETRY_OPTOUT -ne '0') { throw 'Failed validation did not restore caller telemetry settings.' }
    }
    foreach ($metadata in @('<Project><PropertyGroup /></Project>', '<Project><PropertyGroup><Version /></PropertyGroup></Project>',
            '<Project><PropertyGroup><Version>0.1.0</Version></PropertyGroup><PropertyGroup><Version>0.2.0</Version></PropertyGroup></Project>',
            '<Project><PropertyGroup><Version>draft</Version></PropertyGroup></Project>')) {
        [IO.File]::WriteAllText((Join-Path $testRoot 'Directory.Build.props'), $metadata)
        $localValidationState.FailAt = 0
        $localValidationState.Calls = [Collections.Generic.List[string]]::new()
        $failed = $false
        try { & $validator -RepositoryRoot $testRoot -Phase Package 6>&1 | Out-Null }
        catch { $failed = $true }
        if (-not $failed -or $localValidationState.Calls.Count -ne 2) { throw 'Ambiguous or missing package version reached artifact consumers.' }
    }
    Write-Output "Local entry point failure propagation passed: $($commands.Count) command positions, TEMP absent."
}
finally {
    $env:TEMP = $oldTemp
    $env:KEELMATRIX_NO_TELEMETRY = $oldTelemetry
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = $oldCliTelemetry
    $global:LASTEXITCODE = $oldExitCode
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolved.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
