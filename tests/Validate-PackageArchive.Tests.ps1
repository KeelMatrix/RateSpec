[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PackagePath,
    [Parameter(Mandatory)] [string] $SymbolPackagePath,
    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../build/Invoke-NestedPwsh.ps1')
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
        Invoke-NestedPwsh -NoProfile -File $validatorPath `
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

function Edit-Manifest {
    param([string] $Path, [scriptblock] $Edit)
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry = $zip.GetEntry('KeelMatrix.RateSpec.nuspec')
        $reader = [IO.StreamReader]::new($entry.Open())
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $entry.Delete()
        $replacement = & $Edit $text
        if ($null -ne $replacement) {
            $writer = [IO.StreamWriter]::new($zip.CreateEntry('KeelMatrix.RateSpec.nuspec').Open())
            try { $writer.Write($replacement) } finally { $writer.Dispose() }
        }
    }
    finally { $zip.Dispose() }
}

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    Invoke-NestedPwsh -NoProfile -File $validatorPath -PackagePath $PackagePath `
        -SymbolPackagePath $SymbolPackagePath -RepositoryRoot $RepositoryRoot -AllowMissingIcon
    if ($LASTEXITCODE -ne 0) { throw 'The unmodified package archives failed validation.' }

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

    $mutations = @(
        @{ Name = 'missing manifest'; Message = 'missing required entry'; Edit = { param($text) $null } },
        @{ Name = 'wrong ID'; Message = 'identity/version mismatch'; Edit = { param($text) $text.Replace('<id>KeelMatrix.RateSpec</id>', '<id>Other.Package</id>') } },
        @{ Name = 'wrong version'; Message = 'identity/version mismatch'; Edit = { param($text) $text.Replace('<version>0.1.0</version>', '<version>0.2.0</version>') } },
        @{ Name = 'extra dependency'; Message = 'dependency/framework'; Edit = { param($text) $text.Replace('</dependencies>', '<dependency id="Other.Package" version="1.0.0" /></dependencies>') } },
        @{ Name = 'extra grouped dependency'; Message = 'dependency/framework'; Edit = { param($text) $text.Replace('</dependencies>', '<group targetFramework="net8.0"><dependency id="Other.Package" version="1.0.0" /></group></dependencies>') } },
        @{ Name = 'extra empty group'; Message = 'dependency/framework'; Edit = { param($text) $text.Replace('</dependencies>', '<group targetFramework="net9.0" /></dependencies>') } },
        @{ Name = 'misplaced dependency'; Message = 'dependency/framework'; Edit = { param($text) $text.Replace('<group targetFramework="net8.0">', '').Replace('</group>', '') } },
        @{ Name = 'wrong dependency framework'; Message = 'dependency/framework'; Edit = { param($text) $text.Replace('targetFramework="net8.0"', 'targetFramework="net9.0"') } },
        @{ Name = 'wrong dependency version'; Message = 'dependency/framework'; Edit = { param($text) $text.Replace('version="0.1.1"', 'version="0.1.0"') } },
        @{ Name = 'suppressed dependency'; Message = 'dependency/framework'; Edit = { param($text) $text.Replace('id="KeelMatrix.Telemetry"', 'id="KeelMatrix.Telemetry" include="None"') } },
        @{ Name = 'missing framework reference'; Message = 'dependency/framework'; Edit = { param($text) $text -replace '(?s)<frameworkReferences>.*?</frameworkReferences>', '' } },
        @{ Name = 'extra framework reference'; Message = 'dependency/framework'; Edit = { param($text) $text.Replace('<frameworkReference name="Microsoft.AspNetCore.App" />', '<frameworkReference name="Microsoft.AspNetCore.App" /><frameworkReference name="Other.Framework" />') } }
    )
    foreach ($side in @('package', 'symbols')) {
        foreach ($mutation in $mutations) {
            $caseRoot = Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $caseRoot | Out-Null
            $candidate = Join-Path $caseRoot (Split-Path $PackagePath -Leaf)
            $candidateSymbols = Join-Path $caseRoot (Split-Path $SymbolPackagePath -Leaf)
            Copy-Item -LiteralPath $PackagePath -Destination $candidate
            Copy-Item -LiteralPath $SymbolPackagePath -Destination $candidateSymbols
            $target = if ($side -eq 'package') { $candidate } else { $candidateSymbols }
            Edit-Manifest $target $mutation.Edit
            Assert-ArchiveRejected $candidate $candidateSymbols $mutation.Message "$side $($mutation.Name)"
        }
    }
    foreach ($missing in @('_rels/.rels', '[Content_Types].xml', 'all-but-pdb', 'symbol-type')) {
        $caseRoot = Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $caseRoot | Out-Null
        $candidateSymbols = Join-Path $caseRoot (Split-Path $SymbolPackagePath -Leaf)
        Copy-Item -LiteralPath $SymbolPackagePath -Destination $candidateSymbols
        if ($missing -eq 'symbol-type') {
            Edit-Manifest $candidateSymbols { param($text) $text.Replace('name="SymbolsPackage"', 'name="Other"') }
            $message = 'symbol package type'
        }
        else {
            $zip = [IO.Compression.ZipFile]::Open($candidateSymbols, [IO.Compression.ZipArchiveMode]::Update)
            try {
                foreach ($entry in @($zip.Entries)) {
                    if ($entry.FullName -eq $missing -or ($missing -eq 'all-but-pdb' -and -not $entry.FullName.EndsWith('.pdb'))) { $entry.Delete() }
                }
            }
            finally { $zip.Dispose() }
            $message = 'missing required entry'
        }
        Assert-ArchiveRejected $PackagePath $candidateSymbols $message "Symbols $missing"
    }
    foreach ($side in @('package', 'symbols')) {
        $caseRoot = Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $caseRoot | Out-Null
        $candidate = Join-Path $caseRoot (Split-Path $PackagePath -Leaf)
        $candidateSymbols = Join-Path $caseRoot (Split-Path $SymbolPackagePath -Leaf)
        Copy-Item -LiteralPath $PackagePath -Destination $candidate
        Copy-Item -LiteralPath $SymbolPackagePath -Destination $candidateSymbols
        Add-ZipEntry -ArchivePath $(if ($side -eq 'package') { $candidate } else { $candidateSymbols }) -EntryName 'KeelMatrix.RateSpec.nuspec'
        Assert-ArchiveRejected $candidate $candidateSymbols 'duplicate entries' "$side duplicate manifest"
    }
    Write-Output 'Paired package identity, structure, dependency graph and allowlist regression tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
