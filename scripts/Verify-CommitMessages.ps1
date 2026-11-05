[CmdletBinding()]
param(
    [string]$RepositoryPath = (Get-Location).Path,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../build/Invoke-NestedPwsh.ps1')

$policyVersion = 3

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
    $privateIdPrefix = Join-CodePoints @(75, 69, 69)
    $privateIdPattern = '(?i)(?<![\p{L}\p{N}_])' + $privateIdPrefix +
        '(?:[ \t]*[-_\u2010-\u2015\u2212#][ \t]*|[ \t]+|(?=[0-9]))[0-9]+(?![\p{L}\p{N}_])'
    return [regex]::IsMatch($Message, $trailerPattern) -or
        [regex]::IsMatch($Message, (Get-ForbiddenPattern)) -or
        [regex]::IsMatch($Message, $privateIdPattern)
}

if ($SelfTest) {
    $selfTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('commit-policy-' + [Guid]::NewGuid().ToString('N'))
    function Invoke-FixtureGit {
        $result = @(& git -C $selfTestRoot @args)
        if ($LASTEXITCODE -ne 0) { throw 'Fixture Git command failed.' }
        return $result
    }
    function Add-FixtureCommit([string]$Message) {
        [IO.File]::WriteAllText((Join-Path $selfTestRoot 'message.txt'), $Message)
        Invoke-FixtureGit -c commit.gpgSign=false commit --quiet --allow-empty --file message.txt
        return @(Invoke-FixtureGit rev-parse HEAD)[0]
    }
    function Get-FixtureViolations([string[]]$Output) {
        return @($Output | Where-Object { $_ -match '^COMMIT_MESSAGE_VIOLATION=' } |
            ForEach-Object { $_.Substring('COMMIT_MESSAGE_VIOLATION='.Length) } | Sort-Object)
    }
    try {
        New-Item -ItemType Directory -Path $selfTestRoot | Out-Null
        Invoke-FixtureGit init --quiet
        Invoke-FixtureGit config user.name 'KeelMatrix'
        Invoke-FixtureGit config user.email 'keelmatrix@gmail.com'
        $prefix = Join-CodePoints @(75, 69, 69)
        $allowedMessages = @(
            'Fix HTTP-429 handling',
            'Document CWE-123 and GH-42',
            'Accept issue #123',
            "Handle ${prefix}L-123 values",
            "Handle X${prefix}-123 values",
            "Handle 1${prefix}-123 values",
            "Handle _${prefix}-123 values",
            "Handle ${prefix}-123x values",
            "Handle ${prefix}-123_ values",
            "Handle ${prefix}-123$([char]233) values",
            "Handle $([char]233)${prefix}-123 values",
            "Handle ${prefix}-abc values",
            "Handle ${prefix}- values",
            "Handle ${prefix} values",
            "Handle ${prefix}`n123 values"
        )
        foreach ($message in $allowedMessages) { $null = Add-FixtureCommit $message }
        $cleanTip = @(Invoke-FixtureGit rev-parse HEAD)[0]
        $cleanOutput = @(Invoke-NestedPwsh -NoProfile -File $PSCommandPath -RepositoryPath $selfTestRoot 2>&1)
        if ($LASTEXITCODE -ne 0 -or @(Get-FixtureViolations $cleanOutput).Count -ne 0) {
            throw 'Commit-message policy rejected a valid fixture history.'
        }

        $expected = [System.Collections.Generic.List[string]]::new()
        $trailerNames = @('CO-AUTHORED-BY', 'signed-OFF-by', 'Reviewed-BY', 'ACKED-BY',
            'Tested-by', 'REPORTED-BY', 'Suggested-BY', 'Custom-BY')
        foreach ($trailerName in $trailerNames) {
            $expected.Add((Add-FixtureCommit "fixture commit`n`n   ${trailerName}: Example <example@example.invalid>`n"))
        }
        $separators = @('-', '_', ' ', "`t", '#', '', ' - ', ' # ',
            (Join-CodePoints @(8208)), (Join-CodePoints @(8209)),
            (Join-CodePoints @(8210)), (Join-CodePoints @(8211)),
            (Join-CodePoints @(8212)), (Join-CodePoints @(8213)), (Join-CodePoints @(8722)))
        foreach ($separator in $separators) {
            foreach ($spelling in @($prefix, $prefix.ToLowerInvariant())) {
                $id = $spelling + $separator + '123'
                $expected.Add((Add-FixtureCommit "Fix parsing ($id)."))
                $expected.Add((Add-FixtureCommit "Fix parsing`n`nReference: [$id]."))
            }
        }
        $expected.Add((Add-FixtureCommit "Fix parsing ($prefix-123, $prefix-456)"))
        $expected.Add((Add-FixtureCommit "Fix parsing $prefix-0"))
        $expected.Add((Add-FixtureCommit "Fix parsing $prefix-00123"))
        $expected.Add((Add-FixtureCommit "Fix parsing https://example.invalid/issues/$prefix-123"))
        # Leave a valid tip so scanning only HEAD cannot pass the negative control.
        $null = Add-FixtureCommit 'Document parsing boundaries'
        $selfTestOutput = @(Invoke-NestedPwsh -NoProfile -File $PSCommandPath -RepositoryPath $selfTestRoot 2>&1)
        $selfTestExit = $LASTEXITCODE
        $actual = @(Get-FixtureViolations $selfTestOutput)
        if ($selfTestExit -eq 0 -or $actual.Count -ne $expected.Count -or
            ($actual -join ',') -ne (($expected | Sort-Object) -join ',')) {
            throw "Commit-message policy self-test: expected $($expected.Count) rejected commits, got $($actual.Count); child exit $selfTestExit."
        }
        # Keep the violating history reachable only through a secondary ref.
        Invoke-FixtureGit branch rejected-history
        Invoke-FixtureGit update-ref HEAD $cleanTip
        $refOutput = @(Invoke-NestedPwsh -NoProfile -File $PSCommandPath -RepositoryPath $selfTestRoot 2>&1)
        if ($LASTEXITCODE -eq 0 -or
            ((Get-FixtureViolations $refOutput) -join ',') -ne (($expected | Sort-Object) -join ',')) {
            throw 'Commit-message policy did not scan a secondary reachable ref.'
        }
        [IO.File]::WriteAllText((Join-Path $selfTestRoot '.git/shallow'), "$cleanTip`n")
        $shallowOutput = @(Invoke-NestedPwsh -NoProfile -File $PSCommandPath -RepositoryPath $selfTestRoot 2>&1)
        if ($LASTEXITCODE -eq 0 -or ($shallowOutput -join "`n") -notmatch 'requires a non-shallow repository') {
            throw 'Commit-message policy did not reject shallow history.'
        }
        Write-Output "COMMIT_MESSAGE_SELF_TEST=PASS allowed=$($allowedMessages.Count) rejected=$($expected.Count) child_exit=$selfTestExit secondary_ref=PASS shallow=PASS"
    }
    finally {
        $resolvedRoot = [IO.Path]::GetFullPath($selfTestRoot)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Fixture cleanup path is outside temporary storage.'
        }
        if (Test-Path -LiteralPath $resolvedRoot) {
            Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
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
