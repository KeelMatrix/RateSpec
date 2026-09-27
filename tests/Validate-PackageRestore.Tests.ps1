$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$validatorPath = Join-Path $repositoryRoot 'scripts/Validate-PackageRestore.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ratespec-package-restore-$([Guid]::NewGuid().ToString('N'))"
$packagePath = Join-Path $testRoot 'KeelMatrix.RateSpec.0.1.0.nupkg'
$assetsPath = Join-Path $testRoot 'project.assets.json'

function Get-ArchiveHash {
    param([Parameter(Mandatory)] [byte[]] $Bytes)

    [Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData($Bytes))
}

function Set-AssetsHash {
    param([Parameter(Mandatory)] [string] $Hash)

    @{ libraries = @{ 'KeelMatrix.RateSpec/0.1.0' = @{ sha512 = $Hash } } } |
        ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $assetsPath -Encoding utf8
}

function Invoke-RestoreValidator {
    $output = @(
        & pwsh -NoProfile -File $validatorPath -PackagePath $packagePath -AssetsFile $assetsPath 2>&1
    )

    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output | Out-String)
    }
}

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    $producedBytes = [Text.Encoding]::UTF8.GetBytes('produced archive bytes')
    [IO.File]::WriteAllBytes($packagePath, $producedBytes)
    Set-AssetsHash -Hash (Get-ArchiveHash -Bytes $producedBytes)

    $matching = Invoke-RestoreValidator
    if ($matching.ExitCode -ne 0) {
        throw "Exact package restore validation failed unexpectedly: $($matching.Output)"
    }

    $staleBytes = [Text.Encoding]::UTF8.GetBytes('stale same-version archive bytes')
    Set-AssetsHash -Hash (Get-ArchiveHash -Bytes $staleBytes)
    $stale = Invoke-RestoreValidator
    if ($stale.ExitCode -eq 0 -or $stale.Output -notmatch 'does not match the') {
        throw "Warm-cache stale package validation unexpectedly passed: $($stale.Output)"
    }

    Write-Output 'Package restore hash regression tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
