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

    $output = @(
        & pwsh -NoProfile -File (Join-Path $Fixture 'scripts/Validate-Release.ps1') `
            -Tag 'v0.1.0' `
            -RepositoryRoot $Fixture 2>&1
    )

    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
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
