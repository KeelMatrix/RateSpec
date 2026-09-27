[CmdletBinding()]
param(
    [string]$RepositoryPath = (Get-Location).Path,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$policyVersion = 2

function Join-CodePoints {
    param([int[]]$Values)

    return -join ($Values | ForEach-Object { [char]$_ })
}

function Get-ForbiddenPattern {
    $restrictedTerms = @(
        (Join-CodePoints @(112, 97, 112, 101, 114, 99, 108, 105, 112)),
        (Join-CodePoints @(97, 103, 101, 110, 116)),
        (Join-CodePoints @(109, 111, 100, 101, 108)),
        (Join-CodePoints @(112, 114, 111, 109, 112, 116)),
        (Join-CodePoints @(116, 111, 111, 108)),
        (Join-CodePoints @(102, 111, 117, 110, 100, 101, 114)),
        (Join-CodePoints @(102, 114, 111, 110, 116, 105, 101, 114)),
        (Join-CodePoints @(116, 97, 115, 107, 32, 100, 101, 108, 101, 103, 97, 116, 111, 114)),
        (Join-CodePoints @(114, 101, 118, 105, 101, 119, 32, 108, 97, 110, 101)),
        (Join-CodePoints @(105, 110, 116, 101, 114, 110, 97, 108))
    )
    $escapedTerms = $restrictedTerms | ForEach-Object { [regex]::Escape($_) }
    return '(?i)(?:' + ($escapedTerms -join '|') + ')'
}

function Get-MessageRecords {
    param([string]$Path)

    $commits = @(git -C $Path rev-list --all)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to enumerate reachable commit history.'
    }

    foreach ($commit in $commits) {
        $lines = @(git -C $Path show -s --format=%B $commit)
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to read commit $commit."
        }

        [pscustomobject]@{
            Commit = $commit
            Message = $lines -join [Environment]::NewLine
        }
    }
}

function Test-Message {
    param([string]$Message)

    $trailerPattern = '(?im)^\s*[a-z0-9][a-z0-9-]*-by\s*:'
    return [regex]::IsMatch($Message, $trailerPattern) -or [regex]::IsMatch($Message, (Get-ForbiddenPattern))
}

if ($SelfTest) {
    $selfTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('commit-policy-' + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $selfTestRoot | Out-Null
        & git -C $selfTestRoot init --quiet
        & git -C $selfTestRoot config user.name 'KeelMatrix'
        & git -C $selfTestRoot config user.email 'keelmatrix@gmail.com'
        [IO.File]::WriteAllText((Join-Path $selfTestRoot 'history.txt'), 'fixture')
        $trailerNames = @(
            'CO-AUTHORED-BY',
            'signed-OFF-by',
            'Reviewed-BY',
            'ACKED-BY',
            'Tested-by',
            'REPORTED-BY',
            'Suggested-BY',
            'Custom-BY'
        )
        foreach ($trailerName in $trailerNames) {
            [IO.File]::WriteAllText(
                (Join-Path $selfTestRoot 'message.txt'),
                "fixture commit ${trailerName}`n`n   ${trailerName}: Example <example@example.invalid>`n")
            & git -C $selfTestRoot add history.txt message.txt
            & git -C $selfTestRoot commit --quiet --file message.txt
        }

        $selfTestOutput = @(& pwsh -NoProfile -File $PSCommandPath -RepositoryPath $selfTestRoot 2>&1)
        $selfTestExit = $LASTEXITCODE
        $violationCount = @($selfTestOutput | Where-Object { $_ -match '^COMMIT_MESSAGE_VIOLATION=' }).Count
        if ($selfTestExit -eq 0 -or $violationCount -ne $trailerNames.Count) {
            throw 'Commit-message policy self-test failed to detect the fixture violation.'
        }

        Write-Output "COMMIT_MESSAGE_SELF_TEST=PASS child_exit=$selfTestExit"
    }
    finally {
        if (Test-Path -LiteralPath $selfTestRoot) {
            Remove-Item -LiteralPath $selfTestRoot -Recurse -Force
        }
    }
}

$shallowState = @(git -C $RepositoryPath rev-parse --is-shallow-repository 2>$null)
if ($LASTEXITCODE -ne 0 -or $shallowState.Count -eq 0) {
    throw 'Unable to determine whether repository history is complete.'
}
if ($shallowState[0].Trim() -eq 'true') {
    throw 'Commit-message policy requires a non-shallow repository.'
}

$records = @(Get-MessageRecords -Path $RepositoryPath)
$violations = [System.Collections.Generic.List[object]]::new()
foreach ($record in $records) {
    if (Test-Message -Message $record.Message) {
        $violations.Add($record)
    }
}

Write-Output "REACHABLE_COMMIT_COUNT=$($records.Count)"
if ($violations.Count -gt 0) {
    foreach ($violation in $violations) {
        Write-Output "COMMIT_MESSAGE_VIOLATION=$($violation.Commit)"
    }
    throw "Commit message policy version $policyVersion rejected $($violations.Count) reachable commit(s)."
}

Write-Output "COMMIT_MESSAGE_POLICY=PASS version=$policyVersion"
