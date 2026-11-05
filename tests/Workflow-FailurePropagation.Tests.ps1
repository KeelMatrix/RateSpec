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

function Get-StepBody([string] $Workflow, [string] $Step) {
    $pattern = '(?m)^      - name: ' + [regex]::Escape($Step) + '\r?\n(?:(?:        [^\r\n]*\r?\n))*?        run: \|\r?\n(?<body>(?:          [^\r\n]*(?:\r?\n|$)|\r?\n)+)'
    $match = [regex]::Match($Workflow, $pattern)
    if (-not $match.Success) { throw "Missing workflow body: $Step." }
    return $match.Groups['body'].Value -replace '(?m)^          ', ''
}

New-Item -ItemType Directory -Path (Join-Path $testRoot 'artifacts/package') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $testRoot 'artifacts/package/KeelMatrix.RateSpec.0.1.0.nupkg'), '')
[IO.File]::WriteAllText((Join-Path $testRoot 'artifacts/package/KeelMatrix.RateSpec.0.1.0.snupkg'), '')
$previousTag = $env:RELEASE_TAG
$previousExitCode = $global:LASTEXITCODE
Push-Location $testRoot
try {
    $env:RELEASE_TAG = 'v0.1.0'
    $cases = @(
        @{ Workflow = 'release.yml'; Step = 'Validate release metadata'; Commands = 1 },
        @{ Workflow = 'release.yml'; Step = 'Validate release metadata'; Then = 'Inspect exact release artifact set'; Commands = 2 },
        @{ Workflow = 'release.yml'; Step = 'Inspect exact release artifact set'; Commands = 1 },
        @{ Workflow = 'release.yml'; Step = 'Push package'; Commands = 2 },
        @{ Workflow = 'release.yml'; Step = 'Inspect exact release artifact set'; Then = 'Push package'; Commands = 3 }
    )
    foreach ($case in $cases) {
        $workflow = Get-Content -Raw (Join-Path $repositoryRoot ".github/workflows/$($case.Workflow)")
        if ($workflow.Contains('continue-on-error:') -or
            $workflow.IndexOf('- name: Validate release metadata') -lt 0 -or
            $workflow.IndexOf('- name: Validate release metadata') -ge $workflow.IndexOf('- name: Run repository validation') -or
            $workflow.IndexOf('- name: Run repository validation') -ge $workflow.IndexOf('- name: Inspect exact release artifact set') -or
            $workflow.IndexOf('- name: Inspect exact release artifact set') -ge $workflow.IndexOf('- name: NuGet login') -or
            $workflow.IndexOf('- name: NuGet login') -ge $workflow.IndexOf('- name: Push package')) {
            throw 'Release validation must stop the job before authentication and publication.'
        }
        $text = Get-StepBody $workflow $case.Step
        if ($case.ContainsKey('Then')) { $text += "`n" + (Get-StepBody $workflow $case.Then) }
        $body = [scriptblock]::Create($text)
        $commandCount = if ($case.ContainsKey('Commands')) { $case.Commands } else { 2 }
        foreach ($script:failAt in @(0..$commandCount)) {
            $script:callCount = 0
            $global:LASTEXITCODE = 0
            $failed = $false
            try {
                & $body
                $failed = $LASTEXITCODE -ne 0
            }
            catch { $failed = $true }
            $expectedCalls = if ($script:failAt -eq 0) { $commandCount } else { $script:failAt }
            if ($failed -ne ($script:failAt -ne 0) -or $script:callCount -ne $expectedCalls) {
                throw "$($case.Workflow)/$($case.Step): failure at $script:failAt yielded failed=$failed, calls=$script:callCount."
            }
        }
    }
    Write-Output 'Workflow failure propagation passed: release metadata, paired archives and both publication commands fail closed before subsequent steps.'
}
finally {
    $global:LASTEXITCODE = $previousExitCode
    $env:RELEASE_TAG = $previousTag
    Pop-Location
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolvedRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Workflow test cleanup path is outside temporary storage.'
    }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
