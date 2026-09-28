[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Tag,

    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../build/Invoke-NestedPwsh.ps1')
$launchGuard = Join-Path $RepositoryRoot 'build/Test-NestedPwshLaunch.ps1'
& $launchGuard -SelfTest
if ($LASTEXITCODE -ne 0) { throw 'Nested PowerShell launch guard self-test failed.' }
& $launchGuard
if ($LASTEXITCODE -ne 0) { throw 'Nested PowerShell launch guard failed.' }

if ($Tag -notmatch '^v(?<version>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)$') {
    throw "Release tag '$Tag' must use the vX.Y.Z format."
}

$version = $Matches.version + '.' + $Matches.minor + '.' + $Matches.patch
$props = [xml](Get-Content -Raw (Join-Path $RepositoryRoot 'Directory.Build.props'))
$configuredVersion = ([string]$props.Project.PropertyGroup.Version).Trim()
if ($configuredVersion -ne $version) {
    throw "Directory.Build.props Version '$configuredVersion' does not match release version '$version'."
}

$packageProps = [xml](Get-Content -Raw (Join-Path $RepositoryRoot 'Directory.Packages.props'))
$packageVersionNodes = @($packageProps.Project.ItemGroup.PackageVersion | Where-Object Include -eq 'KeelMatrix.RateSpec')
if ($packageVersionNodes.Count -ne 1 -or ([string]$packageVersionNodes[0].Version).Trim() -ne $version) {
    throw "Directory.Packages.props KeelMatrix.RateSpec version does not match release version '$version'."
}

$project = [xml](Get-Content -Raw (Join-Path $RepositoryRoot 'src/KeelMatrix.RateSpec/KeelMatrix.RateSpec.csproj'))
$packageId = $project.Project.PropertyGroup.PackageId
if ($packageId -ne 'KeelMatrix.RateSpec') {
    throw "Shipping project PackageId '$packageId' is not KeelMatrix.RateSpec."
}

$changelogPath = Join-Path $RepositoryRoot 'CHANGELOG.md'
$changelog = Get-Content -Raw $changelogPath
if ($changelog -notmatch '(?m)^## \[Unreleased\]\s*$') {
    throw 'CHANGELOG.md must retain an Unreleased section.'
}

$escapedVersion = [regex]::Escape($version)
$heading = [regex]::Match($changelog, "(?m)^## \[$escapedVersion\] - (?<date>\d{4}-\d{2}-\d{2})\s*$")
if (-not $heading.Success) {
    throw "CHANGELOG.md must contain a dated [$version] release heading."
}

$releaseSectionStart = $heading.Index + $heading.Length
$releaseSectionHeadingPattern = '(?:Unreleased|(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))'
$nextHeading = [regex]::Match(
    $changelog.Substring($releaseSectionStart),
    "(?m)^##[ \t]+\[$releaseSectionHeadingPattern\](?:[ \t]+-[^\r\n]*)?[ \t]*$"
)
$releaseSection = if ($nextHeading.Success) {
    $changelog.Substring($releaseSectionStart, $nextHeading.Index)
}
else {
    $changelog.Substring($releaseSectionStart)
}

if ($releaseSection -match '(?i)\bplanned\b|\bunreleased\b|\btbd\b|not yet published') {
    throw "CHANGELOG.md [$version] section is not finalized."
}

if ($version -eq '0.1.0') {
    # Every Markdown heading in the selected release section is a category.
    # Matching the hash run keeps this rule independent of heading depth.
    $categories = @(
        [regex]::Matches($releaseSection, '(?m)^#{1,}[ \t]+(?<category>[^\r\n]+)[ \t]*$') |
            ForEach-Object { $_.Groups['category'].Value.Trim() }
    )
    if ($categories.Count -ne 1 -or $categories[0] -cne 'Added') {
        throw 'The first public release section must contain only an Added category.'
    }

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
    $markerPattern = '(?i)\b(?:' + (($remediationMarkers | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\b'
    if ($releaseSection -match $markerPattern) {
        throw 'The first public release section contains unpublished remediation or transition wording.'
    }
}

try {
    $releaseDate = [DateTime]::ParseExact($heading.Groups['date'].Value, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
}
catch {
    throw "CHANGELOG.md [$version] contains an invalid release date."
}

if ($releaseDate.Date -gt [DateTime]::UtcNow.Date) {
    throw "CHANGELOG.md [$version] release date cannot be in the future."
}

Write-Output "Release metadata is valid for $Tag ($version)."
