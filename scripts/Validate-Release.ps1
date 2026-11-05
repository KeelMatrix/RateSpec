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
# Supported changelog subset: top-level ATX headings, paragraphs, flat bullets,
# closed fences, standalone comments, escapes and same-line code spans.
# Reject other block/HTML contexts rather than infer heading identity from them.
# See docs/DEV.md for the input contract. Never join text around hidden blocks.
$visible = [Collections.Generic.List[string]]::new()
$fenceCharacter = $null
$fenceLength = 0
$inComment = $false
$inBulletList = $false
$blankBefore = $true
foreach ($line in ($changelog -split '\r?\n')) {
    if ($null -ne $fenceCharacter) {
        if ($line -match ('^ {0,3}' + [regex]::Escape($fenceCharacter) + '{' + $fenceLength + ',}[ \t]*$')) {
            $fenceCharacter = $null
        }
        $visible.Add('')
        continue
    }
    if (-not $inComment -and $line -match '^[ \t]*$') {
        $blankBefore = $true
        $visible.Add('')
        continue
    }
    # An indented fence/comment following a bullet can belong to that list.
    # A later unindented heading would end the container before its delimiter.
    if (-not $inComment -and $inBulletList -and $line -match '^[ \t]+\S') {
        throw 'CHANGELOG.md does not support indented blocks or continuations in bullet lists.'
    }
    if (-not $inComment -and $line -match '^ {0,3}(?<fence>`{3,}|~{3,})(?<info>[^\r\n]*)$') {
        $fenceCharacter = $Matches.fence.Substring(0, 1)
        $fenceLength = $Matches.fence.Length
        if ($fenceCharacter -eq '`' -and $Matches.info.Contains('`')) {
            throw 'CHANGELOG.md backtick fence info strings cannot contain backticks.'
        }
        $inBulletList = $false
        $visible.Add('')
        continue
    }
    $commentText = $line
    if (-not $inComment -and $line -match '^ {0,3}<!--(?<body>.*)$') {
        $commentText = $Matches.body
        if ($commentText.StartsWith('>') -or $commentText.StartsWith('->')) {
            throw 'CHANGELOG.md contains an unsupported HTML comment opener.'
        }
        $inComment = $true
        $inBulletList = $false
    }
    if ($inComment) {
        $end = $commentText.IndexOf('-->', [StringComparison]::Ordinal)
        $body = if ($end -lt 0) { $commentText } else { $commentText.Substring(0, $end) }
        if ($body.Contains('<!--') -or $body.Contains('--')) {
            throw 'CHANGELOG.md contains an unsupported HTML comment body.'
        }
        if ($end -ge 0) {
            if ($commentText.Substring($end + 3).Trim().Length -ne 0 -or $body.EndsWith('-')) {
                throw 'CHANGELOG.md HTML comments must occupy standalone blocks.'
            }
            $inComment = $false
        }
        $visible.Add('')
        continue
    }

    # No indented code, list continuations, quotes, reference definitions or
    # Setext headings: each can alter the block identity of subsequent lines.
    if ($line -match '^[ \t]+\S|^>|^\[[^\]]+\]:|^(?:=+|-+)[ \t]*$|^(?:\*[ \t]*){3,}$|^(?:_[ \t]*){3,}$|^(?:\*|\+|\d+[.)])[ \t]' -or
        $line -match '^-[ \t]+(?:[ \t]|#{1,}(?:[ \t]|$)|>|`{3,}|~{3,}|[-+*](?:[ \t]|$)|\d+[.)][ \t])') {
        throw 'CHANGELOG.md contains unsupported indentation or block syntax; use top-level ATX headings and flat - bullets.'
    }
    if ($line -match '^#+[ \t]+.*[\\`&*_]') {
        throw 'CHANGELOG.md headings must use plain text without escapes, inline code, entities or emphasis.'
    }
    $position = 0
    while ($position -lt $line.Length) {
        if ($line[$position] -eq '\' -and $position + 1 -lt $line.Length) {
            $position += 2
            continue
        }
        if ($line[$position] -eq '`') {
            $run = [regex]::Match($line.Substring($position), '^`+').Length
            $position += $run
            $closing = [regex]::Match($line.Substring($position), '(?<!`)`{' + $run + '}(?!`)')
            if (-not $closing.Success) {
                throw 'CHANGELOG.md inline code spans must close on the same line with an equal backtick run.'
            }
            $position += $closing.Index + $closing.Length
            continue
        }
        if ($line[$position] -eq '<' -or $line.Substring($position).StartsWith('-->', [StringComparison]::Ordinal)) {
            throw 'CHANGELOG.md contains unsupported raw HTML or comment syntax; use standalone comments, escaped text or code.'
        }
        $position++
    }
    if ($line.StartsWith('- ')) { $inBulletList = $true }
    elseif ($blankBefore -or $line -match '^#+[ \t]') { $inBulletList = $false }
    $blankBefore = $false
    $visible.Add($line)
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
