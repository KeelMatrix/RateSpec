[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $PackagePath,

    [Parameter(Mandatory)]
    [string] $AssetsFile
)

$ErrorActionPreference = 'Stop'

$package = Get-Item -LiteralPath $PackagePath -ErrorAction Stop
if ($package.Extension -ne '.nupkg' -or $package.Name -match '\.snupkg$') {
    throw "PackagePath must identify the produced .nupkg (not a symbol package): '$($package.FullName)'."
}

if ($package.Name -notmatch '^KeelMatrix\.(?<packageId>RateSpec)\.(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\.nupkg$') {
    throw "Unexpected package name '$($package.Name)'."
}

$assets = Get-Content -Raw -LiteralPath $AssetsFile | ConvertFrom-Json
$libraryName = "KeelMatrix.$($Matches.packageId)/$($Matches.version)"
$libraryProperty = $assets.libraries.PSObject.Properties | Where-Object Name -eq $libraryName
if ($null -eq $libraryProperty) {
    throw "The consumer assets file does not resolve '$libraryName'."
}

$resolvedHash = [string]$libraryProperty.Value.sha512
if ([string]::IsNullOrWhiteSpace($resolvedHash)) {
    throw "The consumer assets file has no package hash for '$libraryName'."
}

$archiveHash = [Convert]::ToBase64String(
    [Security.Cryptography.SHA512]::HashData([IO.File]::ReadAllBytes($package.FullName)))
if ($resolvedHash -ne $archiveHash) {
    throw "The consumer resolved package hash '$resolvedHash' does not match the produced archive hash '$archiveHash'."
}

Write-Output "Consumer restore resolved the exact produced archive: $($package.Name)."
