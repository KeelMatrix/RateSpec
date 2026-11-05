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
# Read comments and fences in context: comment delimiters inside code are inert.
$visible = [Collections.Generic.List[string]]::new()
$fenceCharacter = $null
$fenceLength = 0
$inComment = $false
foreach ($line in ($changelog -split '\r?\n')) {
    if ($null -ne $fenceCharacter) {
        if ($line -match ('^ {0,3}' + [regex]::Escape($fenceCharacter) + '{' + $fenceLength + ',}[ \t]*$')) {
            $fenceCharacter = $null
        }
        $visible.Add('')
        continue
    }
    if (-not $inComment -and $line -match '^ {0,3}(?<fence>`{3,}|~{3,})[^\r\n]*$') {
        $fenceCharacter = $Matches.fence.Substring(0, 1)
        $fenceLength = $Matches.fence.Length
        $visible.Add('')
        continue
    }
    $text = ''
    $position = 0
    while ($position -lt $line.Length) {
        if ($inComment) {
            $end = $line.IndexOf('-->', $position, [StringComparison]::Ordinal)
            if ($end -lt 0) { $text += ' ' * ($line.Length - $position); break }
            $text += ' ' * ($end + 3 - $position)
            $position = $end + 3
            $inComment = $false
        }
        else {
            $start = $line.IndexOf('<!--', $position, [StringComparison]::Ordinal)
            if ($start -lt 0) { $text += $line.Substring($position); break }
            $text += $line.Substring($position, $start - $position)
            $text += ' ' * 4
            $position = $start + 4
            $inComment = $true
        }
    }
    if ($text.Contains('-->')) { throw 'CHANGELOG.md contains an unsupported HTML comment delimiter.' }
    $visible.Add($text)
}
if ($inComment) { throw 'CHANGELOG.md contains an unterminated HTML comment.' }
if ($null -ne $fenceCharacter) { throw 'CHANGELOG.md contains an unterminated Markdown fence.' }
$changelog = $visible -join "`n"
if ($changelog -cnotmatch '(?m)^## \[Unreleased\][ \t]*$') {
    throw 'CHANGELOG.md must retain an Unreleased section.'
}

$escapedVersion = [regex]::Escape($version)
$targetToken = "(?<![\d.])$escapedVersion(?![\d.])"
$targetHeadings = @([regex]::Matches($changelog, "(?m)^[ \t]*#+[^\r\n]*$targetToken[^\r\n]*$"))
if ($targetHeadings.Count -gt 1) {
    throw "CHANGELOG.md must contain one unique real [$version] release heading."
}
if ($changelog -match "(?m)^[^\r\n]*$targetToken[^\r\n]*\n {0,3}(?:=+|-+)[ \t]*$") {
    throw 'CHANGELOG.md release headings must use ## [version] - YYYY-MM-DD.'
}
$heading = [regex]::Match($changelog, "(?m)^## \[$escapedVersion\] - (?<date>\d{4}-\d{2}-\d{2})[ \t]*$")
if ($targetHeadings.Count -eq 1 -and (-not $heading.Success -or $targetHeadings[0].Index -ne $heading.Index)) {
    throw "CHANGELOG.md must contain a dated [$version] release heading using ## [version] - YYYY-MM-DD."
}
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

if ($releaseSection -match '(?i)\b(?:planned|unreleased|tbd|tba|draft|pending|unpublished)\b|not(?:[ -]+yet)?[ -]+published|to[ -]+be[ -]+released|coming[ -]+soon') {
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
