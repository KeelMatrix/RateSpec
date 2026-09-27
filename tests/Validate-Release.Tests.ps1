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
    New-Item -ItemType Directory -Path (Join-Path $fixture 'scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixture 'src/KeelMatrix.RateSpec') -Force | Out-Null

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

    Write-Output 'Release validator regression tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
