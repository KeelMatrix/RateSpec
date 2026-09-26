[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $PackagePath,

    [Parameter(Mandatory)]
    [string] $SymbolPackagePath,

    [switch] $AllowMissingIcon,

    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Read-ZipText {
    param(
        [Parameter(Mandatory)] [System.IO.Compression.ZipArchive] $Archive,
        [Parameter(Mandatory)] [string] $EntryName
    )

    $entry = $Archive.Entries | Where-Object FullName -eq $EntryName
    if ($null -eq $entry) {
        throw "Package is missing '$EntryName'."
    }

    $reader = [System.IO.StreamReader]::new($entry.Open())
    try {
        return $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }
}

function Read-ZipBytes {
    param(
        [Parameter(Mandatory)] [System.IO.Compression.ZipArchive] $Archive,
        [Parameter(Mandatory)] [string] $EntryName
    )

    $entry = $Archive.Entries | Where-Object FullName -eq $EntryName
    if ($null -eq $entry) {
        throw "Package is missing '$EntryName'."
    }

    $stream = $entry.Open()
    try {
        $memory = [System.IO.MemoryStream]::new()
        try {
            $stream.CopyTo($memory)
            return $memory.ToArray()
        }
        finally {
            $memory.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-PngDimension {
    param(
        [Parameter(Mandatory)] [byte[]] $Bytes,
        [Parameter(Mandatory)] [string] $Path
    )

    $signature = [byte[]](137, 80, 78, 71, 13, 10, 26, 10)
    if ($Bytes.Length -lt 24) {
        throw "Icon '$Path' is not a valid PNG."
    }

    for ($index = 0; $index -lt $signature.Length; $index++) {
        if ($Bytes[$index] -ne $signature[$index]) {
            throw "Icon '$Path' is not a valid PNG."
        }
    }

    $width = ($Bytes[16] -shl 24) -bor ($Bytes[17] -shl 16) -bor ($Bytes[18] -shl 8) -bor $Bytes[19]
    $height = ($Bytes[20] -shl 24) -bor ($Bytes[21] -shl 16) -bor ($Bytes[22] -shl 8) -bor $Bytes[23]
    return [pscustomobject]@{ Width = $width; Height = $height }
}

$packageName = [System.IO.Path]::GetFileName($PackagePath)
if ($packageName -notmatch '^KeelMatrix\.RateSpec\.(?<version>\d+\.\d+\.\d+)\.nupkg$') {
    throw "Unexpected package name '$packageName'."
}

$version = $Matches.version
$archive = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
try {
    $entryNames = @($archive.Entries | ForEach-Object FullName)
    $requiredEntries = @(
        'KeelMatrix.RateSpec.nuspec',
        'README.md',
        'LICENSE',
        'lib/net8.0/KeelMatrix.RateSpec.dll',
        'lib/net8.0/KeelMatrix.RateSpec.xml'
    )

    foreach ($requiredEntry in $requiredEntries) {
        if ($entryNames -notcontains $requiredEntry) {
            throw "Package is missing required entry '$requiredEntry'."
        }
    }

    $sensitiveEntry = $entryNames | Where-Object { $_ -match '(?i)(^|/)(\.env(?:\.|$)|.*\.pfx$|.*\.snk$|keelmatrix\.telemetry\.json$|AGENTS\.md$|\.github/|bin/|obj/)' }
    if ($null -ne $sensitiveEntry) {
        throw "Package contains forbidden entry(s): $($sensitiveEntry -join ', ')."
    }

    $nuspec = [xml](Read-ZipText -Archive $archive -EntryName 'KeelMatrix.RateSpec.nuspec')
    $namespace = [System.Xml.XmlNamespaceManager]::new($nuspec.NameTable)
    $namespace.AddNamespace('n', 'http://schemas.microsoft.com/packaging/2013/05/nuspec.xsd')
    $metadata = $nuspec.SelectSingleNode('/n:package/n:metadata', $namespace)
    if ($null -eq $metadata) {
        throw 'Package nuspec metadata is missing.'
    }

    if ($metadata.id -ne 'KeelMatrix.RateSpec' -or $metadata.version -ne $version) {
        throw "Package identity/version mismatch: '$($metadata.id)' '$($metadata.version)'."
    }

    if ($metadata.readme -ne 'README.md' -or $metadata.license.type -ne 'expression' -or $metadata.license.'#text' -ne 'MIT') {
        throw 'Package README or MIT license metadata is incorrect.'
    }

    $repository = $metadata.repository
    if ($repository.type -ne 'git' -or $repository.url -ne 'https://github.com/KeelMatrix/RateSpec') {
        throw 'Package repository metadata is incorrect.'
    }

    $dependency = @($metadata.dependencies.group.dependency | Where-Object id -eq 'KeelMatrix.Telemetry')
    if ($dependency.Count -ne 1 -or $dependency[0].version -ne '0.1.1') {
        throw 'Package dependency metadata is incorrect.'
    }

    $iconPath = Join-Path $RepositoryRoot 'icon.png'
    $iconEntry = $archive.Entries | Where-Object FullName -eq 'icon.png'
    $metadataIcon = $metadata.icon

    if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) {
        if (-not $AllowMissingIcon) {
            throw "Required founder-supplied icon is absent at '$iconPath'."
        }

        if ($null -ne $iconEntry -or $null -ne $metadataIcon) {
            throw 'The package contains icon metadata or bytes even though the configured icon path is absent.'
        }

        Write-Warning "Founder gate remains open: '$iconPath' is absent. The explicit -AllowMissingIcon pre-release allowance does not satisfy release readiness."
    }
    else {
        $iconBytes = [System.IO.File]::ReadAllBytes($iconPath)
        if ($iconBytes.Length -gt 204800) {
            throw "Icon exceeds the 200 KB limit: $($iconBytes.Length) bytes."
        }

        $dimensions = Get-PngDimension -Bytes $iconBytes -Path $iconPath
        if ($dimensions.Width -ne 512 -or $dimensions.Height -ne 512) {
            throw "Icon must be 512x512 pixels, got $($dimensions.Width)x$($dimensions.Height)."
        }

        if ($null -eq $iconEntry -or $metadataIcon -ne 'icon.png') {
            throw 'Present icon is not both packed as icon.png and referenced by nuspec metadata.'
        }

        $packedIconBytes = Read-ZipBytes -Archive $archive -EntryName 'icon.png'
        $expectedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($iconBytes))
        $packedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($packedIconBytes))
        if ($expectedHash -ne $packedHash) {
            throw "Packed icon hash '$packedHash' differs from repository icon hash '$expectedHash'."
        }
    }
}
finally {
    $archive.Dispose()
}

$symbols = [System.IO.Compression.ZipFile]::OpenRead($SymbolPackagePath)
try {
    $symbolNames = @($symbols.Entries | ForEach-Object FullName)
    if ($symbolNames -notcontains 'lib/net8.0/KeelMatrix.RateSpec.pdb') {
        throw 'Symbol package is missing lib/net8.0/KeelMatrix.RateSpec.pdb.'
    }
}
finally {
    $symbols.Dispose()
}

Write-Output "Package archive is valid: $packageName"
