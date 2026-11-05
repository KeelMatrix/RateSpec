$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$validatorPath = Join-Path $repositoryRoot 'scripts/Validate-Release.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ratespec-release-validator-$([Guid]::NewGuid().ToString('N'))"

function Assert-True {
    param(
        [Parameter(Mandatory)] [bool] $Condition,
        [Parameter(Mandatory)] [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function New-ValidatorFixture {
    $fixture = Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $fixture 'build') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixture 'scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixture 'src/KeelMatrix.RateSpec') -Force | Out-Null

    Copy-Item (Join-Path $repositoryRoot 'build/Invoke-NestedPwsh.ps1') (Join-Path $fixture 'build')
    Copy-Item (Join-Path $repositoryRoot 'build/Test-NestedPwshLaunch.ps1') (Join-Path $fixture 'build')
    Copy-Item (Join-Path $repositoryRoot 'Directory.Build.props') $fixture
    Copy-Item (Join-Path $repositoryRoot 'Directory.Packages.props') $fixture
    Copy-Item (Join-Path $repositoryRoot 'src/KeelMatrix.RateSpec/KeelMatrix.RateSpec.csproj') (Join-Path $fixture 'src/KeelMatrix.RateSpec')
    Copy-Item $validatorPath (Join-Path $fixture 'scripts')
    return $fixture
}

function Set-FixtureChangelog {
    param(
        [Parameter(Mandatory)] [string] $Fixture,
        [Parameter(Mandatory)] [string] $Content
    )

    Set-Content -LiteralPath (Join-Path $Fixture 'CHANGELOG.md') -Value $Content -Encoding utf8
}

function Invoke-FixtureValidator {
    param(
        [Parameter(Mandatory)] [string] $Fixture
    )

    $output = @()
    $exitCode = 0
    try {
        & (Join-Path $Fixture 'scripts/Validate-Release.ps1') `
            -Tag 'v0.1.0' `
            -RepositoryRoot $Fixture 2>&1 | ForEach-Object { $output += $_.ToString() }
    }
    catch {
        $output += $_.Exception.Message
        $exitCode = 1
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output = ($output | Out-String)
    }
}

function Assert-ValidatorPasses {
    param(
        [Parameter(Mandatory)] [string] $Fixture,
        [Parameter(Mandatory)] [string] $Name
    )

    $result = Invoke-FixtureValidator -Fixture $Fixture
    Assert-True ($result.ExitCode -eq 0) "$Name failed unexpectedly: $($result.Output)"
}

function Assert-ValidatorRejects {
    param(
        [Parameter(Mandatory)] [string] $Fixture,
        [Parameter(Mandatory)] [string] $ExpectedMessage,
        [Parameter(Mandatory)] [string] $Name
    )

    $result = Invoke-FixtureValidator -Fixture $Fixture
    Assert-True ($result.ExitCode -ne 0) "$Name unexpectedly passed."
    Assert-True ($result.Output -match [regex]::Escape($ExpectedMessage)) "$Name returned an unexpected error: $($result.Output)"
}

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    $finalized = New-ValidatorFixture
    Set-FixtureChangelog -Fixture $finalized -Content @'
# Changelog

## [Unreleased]

Future changes go here.

## [0.1.0] - 2026-01-01

### Added

- Initial release.
'@
    Assert-ValidatorPasses -Fixture $finalized -Name 'Finalized changelog'

    $unreleasedMarker = New-ValidatorFixture
    Set-FixtureChangelog -Fixture $unreleasedMarker -Content @'
# Changelog

## [Unreleased]

- Fixed an unreleased draft detail.

## [0.1.0] - 2026-01-01

### Added

- Initial release.
'@
    Assert-ValidatorPasses -Fixture $unreleasedMarker -Name 'Unreleased section isolation'

    $firstReleaseCategoryNames = @('Changed', 'Fixed', 'Deprecated', 'Removed', 'Security', 'Compatibility', 'Notes')
    $firstReleaseHeadingDepths = @('#', '##', '###', '####', '#####', '######', '#######')
    foreach ($depth in $firstReleaseHeadingDepths) {
        foreach ($category in $firstReleaseCategoryNames) {
            $categoryFixture = New-ValidatorFixture
            Set-FixtureChangelog -Fixture $categoryFixture -Content @"
# Changelog

## [Unreleased]

## [0.1.0] - 2026-01-01

### Added

- Initial release.

$depth $category

- Additional release detail.
"@
            Assert-ValidatorRejects -Fixture $categoryFixture -ExpectedMessage 'must contain only an Added category' -Name "First-release $depth $category category"
        }
    }

    $nestedCategory = New-ValidatorFixture
    Set-FixtureChangelog -Fixture $nestedCategory -Content @'
# Changelog

## [Unreleased]

## [0.1.0] - 2026-01-01

### Added

- Initial release.

#### Changed

- Additional release detail.
'@
    Assert-ValidatorRejects -Fixture $nestedCategory -ExpectedMessage 'must contain only an Added category' -Name 'Nested first-release category'

    $futureRelease = New-ValidatorFixture
    Set-FixtureChangelog -Fixture $futureRelease -Content @'
# Changelog

## [Unreleased]

## [0.1.0] - 2026-01-01

### Added

- Initial release.

## [0.2.0] - 2026-02-01

### Changed

- Future release detail.
'@
    Assert-ValidatorPasses -Fixture $futureRelease -Name 'Release section isolation'

    $remediationMarkers = @(
        'now',
        'no longer',
        'previously',
        'formerly',
        'used to',
        'fixed',
        'fixes',
        'corrected',
        'resolved',
        'addressed',
        'this removes',
        'this fixes',
        'changed from'
    )
    foreach ($marker in $remediationMarkers) {
        $markerFixture = New-ValidatorFixture
        Set-FixtureChangelog -Fixture $markerFixture -Content @"
# Changelog

## [Unreleased]

## [0.1.0] - 2026-01-01

### Added

- The package $marker this pre-release behavior.
"@
        Assert-ValidatorRejects -Fixture $markerFixture -ExpectedMessage 'unpublished remediation or transition wording' -Name "First-release marker '$marker'"
    }

    $mismatch = New-ValidatorFixture
    Set-FixtureChangelog -Fixture $mismatch -Content @'
# Changelog

## [Unreleased]

## [0.1.0] - 2026-01-01

### Added

- Initial release.
'@
    $propsPath = Join-Path $mismatch 'Directory.Build.props'
    (Get-Content -Raw $propsPath).Replace('<Version>0.1.0</Version>', '<Version>0.2.0</Version>') | Set-Content -LiteralPath $propsPath -Encoding utf8
    Assert-ValidatorRejects -Fixture $mismatch -ExpectedMessage 'Directory.Build.props Version' -Name 'Version mismatch'

    $planned = New-ValidatorFixture
    Set-FixtureChangelog -Fixture $planned -Content @'
# Changelog

## [Unreleased]

## [0.1.0] - Planned

### Added

- Initial release.
'@
    Assert-ValidatorRejects -Fixture $planned -ExpectedMessage 'must contain a dated [0.1.0] release heading' -Name 'Planned changelog'

    $unfinalized = New-ValidatorFixture
    Set-FixtureChangelog -Fixture $unfinalized -Content @'
# Changelog

## [Unreleased]

## [0.1.0] - 2026-01-01

This release is not yet published.
'@
    Assert-ValidatorRejects -Fixture $unfinalized -ExpectedMessage 'section is not finalized' -Name 'Unfinalized changelog'

    $dated = "## [0.1.0] - 2026-01-01`n`n### Added`n`n- Initial release."
    $plannedHeading = "## [0.1.0] - Planned`n`n### Added`n`n- Initial release."
    $prefix = "# Changelog`n`n## [Unreleased]`n`n"
    $invalidChangelogs = @(
        "$dated`n`n$plannedHeading",
        "$plannedHeading`n`n$dated",
        "$dated`n`n$dated",
        "$plannedHeading`n`n``````markdown`n$dated`n``````",
        "$plannedHeading`n`n~~~markdown`n$dated`n~~~",
        "$plannedHeading`n`n<!--`n$dated`n-->",
        "<!-- $dated -->",
        "```````n$dated`n``````",
        "$dated`n`n```````n<!--`n```````n$plannedHeading`n-->"
    )
    foreach ($text in $invalidChangelogs) {
        $fixture = New-ValidatorFixture
        Set-FixtureChangelog $fixture "$prefix$text"
        $result = Invoke-FixtureValidator $fixture
        Assert-True ($result.ExitCode -ne 0) "Duplicate or non-real target unexpectedly passed: $text"
    }

    foreach ($heading in @('# [0.1.0] - 2026-01-01', '### [0.1.0] - 2026-01-01', '## 0.1.0 - 2026-01-01',
            '## [0.1.0] - 2026-01-01 ##', '  ## [0.1.0] - 2026-01-01', '[0.1.0] - 2026-01-01' + "`n------------------")) {
        foreach ($withReal in @($false, $true)) {
            $fixture = New-ValidatorFixture
            $extra = if ($withReal) { "$dated`n`n" } else { '' }
            Set-FixtureChangelog $fixture "$prefix$extra$heading`n`n### Added`n`n- Initial release."
            $result = Invoke-FixtureValidator $fixture
            Assert-True ($result.ExitCode -ne 0) "Ambiguous target heading unexpectedly passed: $heading"
        }
    }
    foreach ($draft in @('Planned', 'UNRELEASED', 'TBD', 'TBA', 'Draft', 'Pending', 'Unpublished', 'not yet published', 'not published', 'not-yet-published', 'to be released', 'to-be-released', 'coming soon')) {
        $fixture = New-ValidatorFixture
        Set-FixtureChangelog $fixture "$prefix$dated`n`n$draft"
        Assert-ValidatorRejects $fixture 'section is not finalized' "Draft marker $draft"
    }
    $fixture = New-ValidatorFixture
    Set-FixtureChangelog $fixture "$prefix$dated`n`n<!--`n$plannedHeading`n-->`n`n~~~`n$plannedHeading`n~~~`n`n## [0.2.0] - Planned`n`n### Changed`n`n- Draft."
    Assert-ValidatorPasses $fixture 'Real section excludes commented/fenced and adjacent entries'
    $fixture = New-ValidatorFixture
    Set-FixtureChangelog $fixture "$prefix$dated`n`n```````n<!--`n```````n`n<!--`n~~~`n$plannedHeading`n-->"
    Assert-ValidatorPasses $fixture 'Comment and fence delimiters respect their context'

    # Exercise the public validator, including literal delimiters that must not
    # change block context. Reuse one non-icon fixture for the bounded matrix.
    $boundaryFixture = New-ValidatorFixture
    $boundaryCount = 0
    function Assert-Boundary([string] $Name, [string] $Text, [bool] $ShouldPass) {
        Set-FixtureChangelog $boundaryFixture "$prefix$Text"
        $result = Invoke-FixtureValidator $boundaryFixture
        Assert-True (($result.ExitCode -eq 0) -eq $ShouldPass) "$Name expected pass=$ShouldPass; $($result.Output)"
        $script:boundaryCount++
    }

    foreach ($length in 1..4) {
        $ticks = '`' * $length
        foreach ($literal in @("${ticks}<!--${ticks}", "${ticks}-->${ticks}", "${ticks}<!-- ``nested`` -->${ticks}")) {
            # A run inside a span can have another length; equal runs close it.
            if ($literal -eq "${ticks}<!-- ``nested`` -->${ticks}" -and $length -eq 1) { continue }
            Assert-Boundary "Literal code run $length" "Literal $literal`n`n$dated" $true
        }
        foreach ($reverse in @($false, $true)) {
            $fakeComment = "Literal ${ticks}<!--${ticks}`n$plannedHeading`nLiteral ${ticks}-->${ticks}"
            $text = if ($reverse) { "$dated`n`n$fakeComment" } else { "$fakeComment`n`n$dated" }
            Assert-Boundary "Literal duplicate $length/$reverse" $text $false
        }
    }
    foreach ($slashes in 1..4) {
        $escape = '\' * $slashes
        $literal = "${escape}<!--`n$plannedHeading`n${escape}-->"
        foreach ($reverse in @($false, $true)) {
            $text = if ($reverse) { "$dated`n`n$literal" } else { "$literal`n`n$dated" }
            Assert-Boundary "Escaped duplicate $slashes/$reverse" $text $false
        }
        Assert-Boundary "Escaped literal control $slashes" "${escape}<!--`n`n$dated" ($slashes % 2 -eq 1)
    }

    foreach ($character in @('`', '~')) {
        foreach ($length in @(3, 4)) {
            $open = $character * $length
            foreach ($info in @('', 'markdown', 'bad`info', 'bad``info', 'escaped\`info', '<!--')) {
                $valid = $character -eq '~' -or -not $info.Contains('`')
                Assert-Boundary "Fence info $character/$length/$info" "$open$info`n$plannedHeading`n$open`n`n$dated" $valid
            }
            foreach ($indent in 0..4) {
                $spaces = ' ' * $indent
                Assert-Boundary "Fence indent $character/$length/$indent" "${spaces}$open`n$plannedHeading`n${spaces}$open`n`n$dated" ($indent -le 3)
            }
            foreach ($closingLength in @(($length - 1), $length, ($length + 1))) {
                $close = $character * $closingLength
                Assert-Boundary "Fence length $character/$length/$closingLength" "$open`n$plannedHeading`n$close`n`n$dated" ($closingLength -ge $length)
            }
            $other = if ($character -eq '`') { '~' * $length } else { '`' * $length }
            foreach ($close in @($other, "$open suffix", "$open<!-- -->", "    $open")) {
                Assert-Boundary "Invalid fence close $character/$length/$close" "$open`n$plannedHeading`n$close`n`n$dated" $false
            }
        }
    }

    $rawBlocks = @(
        @('<pre>', '</pre>'), @('<PRE>', '</PRE>'), @('<script>', '</script>'), @('<style>', '</style>'),
        @('<div>', '</div>'), @('<textarea>', '</textarea>'), @('<custom attr="value">', '</custom>'),
        @('</div>', ''), @('<![CDATA[', ']]>'), @('<!DOCTYPE', '>'), @('<?test', '?>')
    )
    foreach ($block in $rawBlocks) {
        $fake = "$($block[0])`n$dated`n$($block[1])"
        Assert-Boundary "Raw HTML only $($block[0])" $fake $false
        Assert-Boundary "Raw HTML before real $($block[0])" "$fake`n`n$dated" $false
        Assert-Boundary "Raw HTML after real $($block[0])" "$dated`n`n$fake" $false
        Assert-Boundary "Raw HTML in code $($block[0])" "~~~`n$fake`n~~~`n`n$dated" $true
        Assert-Boundary "Raw HTML in comment $($block[0])" "<!--`n$fake`n-->`n`n$dated" $true
    }
    foreach ($comment in @("<!-- ignored -->", " <!--`n$plannedHeading`n -->", "   <!--`n~~~`n$plannedHeading`n``inline`` ```n   -->")) {
        Assert-Boundary 'Standalone comment before real' "$comment`n`n$dated" $true
        Assert-Boundary 'Standalone comment after real' "$dated`n`nEnd of notes.`n`n$comment" $true
        Assert-Boundary 'Only commented target' "<!--`n$dated`n-->" $false
    }
    foreach ($ambiguous in @(
            "<!-- -->## [0.1.0] - Planned", "<!--`n--> ## [0.1.0] - Planned", 'text <!--',
            '<!-- nested <!-- -->', '<!-- invalid -- body -->', '<!-- unclosed', '-->',
            '`unclosed', '``unclosed', "``start`n$plannedHeading`n``end", '> quoted', '    indented',
            "`tindented", ('- outer' + "`n  - nested"), '<https://example.com>', '[ref]: <example>',
            "text`n-----", "[0.1.0] - Planned`n=====", '***', '_ _ _',
            '## [0\.1\.0] - Planned', '## [0&#46;1&#46;0] - Planned', '## **[0.1.0]** - Planned')) {
        Assert-Boundary "Unsupported structure $ambiguous" "$ambiguous`n`n$dated" $false
    }
    Assert-Boundary 'Adjacent section after literal control' ('`<!--`' + "`n`n$dated`n`n## [0.2.0] - Planned`n`n### Changed`n`n- Draft.") $true
    Assert-Boundary 'Escaped code delimiter followed by real comment is unsupported' ('\`<!--' + "`n$plannedHeading`n-->`n`n$dated") $false
    foreach ($nested in @('- ## [0.1.0] - Planned', '- > quote', '- - nested', '- + nested', '-  indented', '- 1. nested')) {
        Assert-Boundary "Nested bullet block $nested" "$nested`n`n$dated" $false
    }
    foreach ($gap in @("`n", "`n`n", "`ncontinuation`n", "`ncontinuation`n`n")) {
        foreach ($indent in 1..3) {
            $spaces = ' ' * $indent
            foreach ($delimiter in @(@('~~~', '~~~'), @('<!--', '-->'))) {
                $block = "$spaces$($delimiter[0])`n$plannedHeading`n$spaces$($delimiter[1])"
                Assert-Boundary "List container delimiter $indent/$gap/$($delimiter[0])" "- Item$gap$block`n`n$dated" $false
            }
        }
    }
    Assert-Boundary 'Unindented fence ends list container' "- Item`n~~~`n$plannedHeading`n~~~`n`n$dated" $true
    Write-Output "Release lexical boundary matrix passed: $boundaryCount cases."

    # Check native exit status as used by local validation and release CI.
    Set-FixtureChangelog $boundaryFixture "$prefix$dated"
    & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $boundaryFixture 'scripts/Validate-Release.ps1') -Tag v0.1.0 -RepositoryRoot $boundaryFixture *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'Finalized metadata did not return native success.'
    Set-FixtureChangelog $boundaryFixture "$prefix$plannedHeading"
    & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $boundaryFixture 'scripts/Validate-Release.ps1') -Tag v0.1.0 -RepositoryRoot $boundaryFixture *> $null
    Assert-True ($LASTEXITCODE -ne 0) 'Invalid metadata did not return native failure.'
    $global:LASTEXITCODE = 0
    Write-Output 'Release validator regression tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
