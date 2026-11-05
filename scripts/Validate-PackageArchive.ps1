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
. (Join-Path $PSScriptRoot '../build/Read-BigEndianUInt32.ps1')
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

    $width = Read-BigEndianUInt32 -Bytes $Bytes -Offset 16
    $height = Read-BigEndianUInt32 -Bytes $Bytes -Offset 20
    return [pscustomobject]@{ Width = $width; Height = $height }
}

function Assert-ArchiveStructure {
    param([IO.Compression.ZipArchive] $Archive, [string[]] $Required, [string] $Label)
    $names = @($Archive.Entries | ForEach-Object FullName)
    if (@($names | Group-Object | Where-Object Count -ne 1).Count -ne 0) {
        throw "$Label contains duplicate entries."
    }
    foreach ($name in @('_rels/.rels', '[Content_Types].xml', 'KeelMatrix.RateSpec.nuspec') + $Required) {
        if ($names -cnotcontains $name) { throw "$Label is missing required entry '$name'." }
    }
    if (@($names | Where-Object { $_ -cmatch '^package/services/metadata/core-properties/[0-9a-f]{32}\.psmdcp$' }).Count -ne 1) {
        throw "$Label is missing required entry for core properties."
    }
}

function Assert-NuspecGraph {
    param([xml] $Nuspec, [string] $Version, [string] $Label, [switch] $Symbols)
    $ns = [Xml.XmlNamespaceManager]::new($Nuspec.NameTable)
    $ns.AddNamespace('n', 'http://schemas.microsoft.com/packaging/2013/05/nuspec.xsd')
    $nodes = @($Nuspec.SelectNodes('/n:package/n:metadata', $ns))
    if ($nodes.Count -ne 1) { throw "$Label nuspec metadata is missing or ambiguous." }
    $m = $nodes[0]
    if (@($m.SelectNodes('n:id', $ns)).Count -ne 1 -or @($m.SelectNodes('n:version', $ns)).Count -ne 1 -or
        $m.id -cne 'KeelMatrix.RateSpec' -or $m.version -cne $Version) {
        throw "$Label identity/version mismatch."
    }
    $dependencies = @($m.SelectNodes('n:dependencies/n:group/n:dependency', $ns))
    $frameworks = @($m.SelectNodes('n:frameworkReferences/n:group/n:frameworkReference', $ns))
    if (@($m.SelectNodes('n:dependencies', $ns)).Count -ne 1 -or
        @($m.SelectNodes('n:dependencies/*', $ns)).Count -ne 1 -or
        @($m.SelectNodes('n:dependencies/n:group/*', $ns)).Count -ne 1 -or
        $m.dependencies.group.targetFramework -cne 'net8.0' -or
        $dependencies.Count -ne 1 -or $dependencies[0].id -cne 'KeelMatrix.Telemetry' -or
        $dependencies[0].version -cne '0.1.1' -or $dependencies[0].exclude -cne 'Build,Analyzers' -or
        $dependencies[0].Attributes.Count -ne 3 -or $m.dependencies.group.Attributes.Count -ne 1 -or
        @($m.SelectNodes('n:frameworkReferences', $ns)).Count -ne 1 -or
        @($m.SelectNodes('n:frameworkReferences/*', $ns)).Count -ne 1 -or
        @($m.SelectNodes('n:frameworkReferences/n:group/*', $ns)).Count -ne 1 -or
        $m.frameworkReferences.group.targetFramework -cne 'net8.0' -or
        $frameworks.Count -ne 1 -or $frameworks[0].name -cne 'Microsoft.AspNetCore.App' -or
        $frameworks[0].Attributes.Count -ne 1 -or $m.frameworkReferences.group.Attributes.Count -ne 1 -or
        @($m.SelectNodes('.//*[local-name()="dependency"]')).Count -ne 1 -or
        @($m.SelectNodes('.//*[local-name()="frameworkReference"]')).Count -ne 1 -or
        @($m.SelectNodes('.//*[local-name()="group"]')).Count -ne 2 -or
        @($m.SelectNodes('.//*[local-name()="frameworkAssemblies" or local-name()="references"]')).Count -ne 0) {
        throw "$Label dependency/framework metadata does not match the intended net8.0 graph."
    }
    if ($Symbols -and (@($m.SelectNodes('n:packageTypes/n:packageType', $ns)).Count -ne 1 -or
            $m.packageTypes.packageType.name -cne 'SymbolsPackage')) {
        throw 'The symbol package type must be SymbolsPackage.'
    }
}

$packageName = [System.IO.Path]::GetFileName($PackagePath)
if ($packageName -notmatch '^KeelMatrix\.RateSpec\.(?<version>\d+\.\d+\.\d+)\.nupkg$') {
    throw "Unexpected package name '$packageName'."
}

$version = $Matches.version
if ([IO.Path]::GetFileName($SymbolPackagePath) -cne "KeelMatrix.RateSpec.$version.snupkg") {
    throw 'Symbol package filename does not match the primary package identity/version.'
}
$archive = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
try {
    Assert-ArchiveStructure $archive @('README.md', 'LICENSE', 'lib/net8.0/KeelMatrix.RateSpec.dll', 'lib/net8.0/KeelMatrix.RateSpec.xml') 'Package'
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

    $allowedEntryPatterns = @(
        '^_rels/\.rels$',
        '^KeelMatrix\.RateSpec\.nuspec$',
        '^lib/net8\.0/KeelMatrix\.RateSpec\.dll$',
        '^lib/net8\.0/KeelMatrix\.RateSpec\.xml$',
        '^README\.md$',
        '^LICENSE$',
        '^\[Content_Types\]\.xml$',
        '^package/services/metadata/core-properties/[0-9a-f]{32}\.psmdcp$',
        '^icon\.png$'
    )
    $unexpectedEntries = @($entryNames | Where-Object {
        $entryName = $_
        -not ($allowedEntryPatterns | Where-Object { $entryName -match $_ })
    })
    if ($unexpectedEntries.Count -gt 0) {
        throw "Package contains unexpected entry(s): $($unexpectedEntries -join ', ')."
    }

    $repositoryInstructionFile = 'AG' + 'ENTS.md'
    $sensitiveEntry = $entryNames | Where-Object { $_ -match ('(?i)(^|/)(\.env(?:\.|$)|.*\.pfx$|.*\.snk$|keelmatrix\.telemetry\.json$|' + [regex]::Escape($repositoryInstructionFile) + '$|\.github/|bin/|obj/)') }
    if ($null -ne $sensitiveEntry) {
        throw "Package contains forbidden entry(s): $($sensitiveEntry -join ', ')."
    }

    $nuspec = [xml](Read-ZipText -Archive $archive -EntryName 'KeelMatrix.RateSpec.nuspec')
    Assert-NuspecGraph $nuspec $version 'Package'
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

    $iconPath = Join-Path $RepositoryRoot 'icon.png'
    $iconEntry = $archive.Entries | Where-Object FullName -eq 'icon.png'
    $metadataIcon = $metadata.icon

    if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) {
        if (-not $AllowMissingIcon) {
            throw "Required repository icon is absent at '$iconPath'."
        }

        if ($null -ne $iconEntry -or $null -ne $metadataIcon) {
            throw 'The package contains icon metadata or bytes even though the configured icon path is absent.'
        }

        Write-Warning "Icon gate: repository icon is absent at '$iconPath'. The explicit -AllowMissingIcon pre-release allowance does not satisfy release readiness."
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
    Assert-ArchiveStructure $symbols @('lib/net8.0/KeelMatrix.RateSpec.pdb') 'Symbol package'
    $symbolNuspec = [xml](Read-ZipText -Archive $symbols -EntryName 'KeelMatrix.RateSpec.nuspec')
    Assert-NuspecGraph $symbolNuspec $version 'Symbol package' -Symbols
    $symbolNames = @($symbols.Entries | ForEach-Object FullName)
    if ($symbolNames -notcontains 'lib/net8.0/KeelMatrix.RateSpec.pdb') {
        throw 'Symbol package is missing lib/net8.0/KeelMatrix.RateSpec.pdb.'
    }

    $allowedSymbolPatterns = @(
        '^_rels/\.rels$',
        '^KeelMatrix\.RateSpec\.nuspec$',
        '^lib/net8\.0/KeelMatrix\.RateSpec\.pdb$',
        '^\[Content_Types\]\.xml$',
        '^package/services/metadata/core-properties/[0-9a-f]{32}\.psmdcp$'
    )
    $unexpectedSymbolEntries = @($symbolNames | Where-Object {
        $entryName = $_
        -not ($allowedSymbolPatterns | Where-Object { $entryName -match $_ })
    })
    if ($unexpectedSymbolEntries.Count -gt 0) {
        throw "Symbol package contains unexpected entry(s): $($unexpectedSymbolEntries -join ', ')."
    }
}
finally {
    $symbols.Dispose()
}

Write-Output "Package archive is valid: $packageName"
