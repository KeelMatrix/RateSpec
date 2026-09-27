[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PackagePath,
    [Parameter(Mandatory)] [string] $SymbolPackagePath,
    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$validatorPath = Join-Path $RepositoryRoot 'scripts/Validate-PackageArchive.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ratespec-package-archive-$([Guid]::NewGuid().ToString('N'))"

function Add-ZipEntry {
    param(
        [Parameter(Mandatory)] [string] $ArchivePath,
        [Parameter(Mandatory)] [string] $EntryName
    )

    $archive = [IO.Compression.ZipFile]::Open($ArchivePath, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry = $archive.CreateEntry($EntryName)
        $writer = [IO.StreamWriter]::new($entry.Open())
        try {
            $writer.Write('unexpected content')
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Assert-ArchiveRejected {
    param(
        [Parameter(Mandatory)] [string] $CandidatePackage,
        [Parameter(Mandatory)] [string] $CandidateSymbols,
        [Parameter(Mandatory)] [string] $ExpectedMessage,
        [Parameter(Mandatory)] [string] $Name
    )

    $output = @(
        & pwsh -NoProfile -File $validatorPath `
            -PackagePath $CandidatePackage `
            -SymbolPackagePath $CandidateSymbols `
            -RepositoryRoot $RepositoryRoot `
            -AllowMissingIcon 2>&1
    )
    if ($LASTEXITCODE -eq 0) {
        throw "$Name unexpectedly passed."
    }

    $text = $output | Out-String
    if ($text -notmatch [regex]::Escape($ExpectedMessage)) {
        throw "$Name returned an unexpected error: $text"
    }
}

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    $extraPackage = Join-Path $testRoot (Split-Path $PackagePath -Leaf)
    $extraSymbols = Join-Path $testRoot (Split-Path $SymbolPackagePath -Leaf)
    Copy-Item -LiteralPath $PackagePath -Destination $extraPackage
    Copy-Item -LiteralPath $SymbolPackagePath -Destination $extraSymbols
    Add-ZipEntry -ArchivePath $extraPackage -EntryName 'unexpected-release-file.txt'
    Assert-ArchiveRejected -CandidatePackage $extraPackage -CandidateSymbols $extraSymbols -ExpectedMessage 'Package contains unexpected entry' -Name 'Unexpected package content'

    $symbolsCaseRoot = Join-Path $testRoot 'symbols-case'
    New-Item -ItemType Directory -Path $symbolsCaseRoot -Force | Out-Null
    $extraPackage = Join-Path $symbolsCaseRoot (Split-Path $PackagePath -Leaf)
    Copy-Item -LiteralPath $PackagePath -Destination $extraPackage
    $extraSymbols = Join-Path $symbolsCaseRoot (Split-Path $SymbolPackagePath -Leaf)
    Copy-Item -LiteralPath $SymbolPackagePath -Destination $extraSymbols -Force
    Add-ZipEntry -ArchivePath $extraSymbols -EntryName 'unexpected-symbol-file.txt'
    Assert-ArchiveRejected -CandidatePackage $extraPackage -CandidateSymbols $extraSymbols -ExpectedMessage 'Symbol package contains unexpected entry' -Name 'Unexpected symbol content'

    Write-Output 'Package archive allowlist regression tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
