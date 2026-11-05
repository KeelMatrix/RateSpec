$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "ratespec-workflow-$([Guid]::NewGuid().ToString('N'))"

function Invoke-NativeStub {
    $script:callCount++
    $global:LASTEXITCODE = if ($script:callCount -eq $script:failAt) { 23 } else { 0 }
}

# Execute the actual workflow bodies with inert native-command substitutes.
function dotnet {
    if ($args[0] -eq 'nuget' -and $args[1] -eq 'push' -and
        $args[2].EndsWith('.nupkg') -and $args -notcontains '--no-symbols') {
        throw 'The primary package push must disable implicit symbol submission.'
    }
    Invoke-NativeStub
}
function pwsh { Invoke-NativeStub }

New-Item -ItemType Directory -Path (Join-Path $testRoot 'artifacts/package') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $testRoot 'artifacts/package/KeelMatrix.RateSpec.0.1.0.nupkg'), '')
[IO.File]::WriteAllText((Join-Path $testRoot 'artifacts/package/KeelMatrix.RateSpec.0.1.0.snupkg'), '')
$previousTag = $env:RELEASE_TAG
Push-Location $testRoot
try {
    $env:RELEASE_TAG = 'v0.1.0'
    $cases = @(
        @{ Workflow = 'ci.yml'; Step = 'Verify formatting' },
        @{ Workflow = 'ci.yml'; Step = 'Inspect package archives' },
        @{ Workflow = 'release.yml'; Step = 'Verify formatting' },
        @{ Workflow = 'release.yml'; Step = 'Push package' }
    )
    foreach ($case in $cases) {
        $workflow = Get-Content -Raw (Join-Path $repositoryRoot ".github/workflows/$($case.Workflow)")
        $pattern = '(?m)^      - name: ' + [regex]::Escape($case.Step) + '\r?\n(?:(?:        [^\r\n]*\r?\n))*?        run: \|\r?\n(?<body>(?:          [^\r\n]*(?:\r?\n|$)|\r?\n)+)'
        $match = [regex]::Match($workflow, $pattern)
        if (-not $match.Success) { throw "Missing workflow body: $($case.Workflow)/$($case.Step)." }
        $body = [scriptblock]::Create(($match.Groups['body'].Value -replace '(?m)^          ', ''))
        foreach ($script:failAt in @(0, 1, 2)) {
            $script:callCount = 0
            $global:LASTEXITCODE = 0
            $failed = $false
            try {
                & $body
                $failed = $LASTEXITCODE -ne 0
            }
            catch { $failed = $true }
            $expectedCalls = if ($script:failAt -eq 1) { 1 } else { 2 }
            if ($failed -ne ($script:failAt -ne 0) -or $script:callCount -ne $expectedCalls) {
                throw "$($case.Workflow)/$($case.Step): failure at $script:failAt yielded failed=$failed, calls=$script:callCount."
            }
        }
    }
    Write-Output 'Workflow failure propagation passed: four bodies, success and each native-command failure.'
}
finally {
    $env:RELEASE_TAG = $previousTag
    Pop-Location
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolvedRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Workflow test cleanup path is outside temporary storage.'
    }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
