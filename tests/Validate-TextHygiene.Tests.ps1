$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$checkerPath = (Resolve-Path $PSCommandPath).Path
$textExtensions = @(
    '.cs', '.csproj', '.md', '.nuspec', '.props', '.ps1', '.sh', '.targets', '.txt', '.yml', '.yaml'
)
$excludedPathFragments = @(
    '\.git[\\/]', '[\\/]artifacts[\\/]', '[\\/]bin[\\/]', '[\\/]obj[\\/]'
)
$releaseRoots = @($repositoryRoot)
$patterns = @(
    '(?i)\bfounder\b',
    '(?i)\bfrontier\b',
    '(?i)Task Delegator',
    '(?i)\bPaperclip\b',
    '(?i)\bagents?\b',
    '(?i)review lane',
    '(?i)KEE-'
)

$files = @(
    foreach ($root in $releaseRoots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        $items = if ((Get-Item -LiteralPath $root).PSIsContainer) {
            Get-ChildItem -LiteralPath $root -Recurse -File -Force
        }
        else {
            Get-Item -LiteralPath $root
        }

        foreach ($item in $items) {
            if ($item.Extension.ToLowerInvariant() -notin $textExtensions) {
                continue
            }

            if ($item.Name -eq 'AGENTS.md' -or $item.FullName -eq $checkerPath -or ($excludedPathFragments | Where-Object { $item.FullName -match $_ })) {
                continue
            }

            $item.FullName
        }
    }
) | Sort-Object -Unique

$violations = @(
    foreach ($path in $files) {
        $content = Get-Content -LiteralPath $path -Raw
        foreach ($pattern in $patterns) {
            if ($content -match $pattern) {
                [pscustomobject]@{
                    Path = $path.Substring($repositoryRoot.Length + 1)
                    Pattern = $pattern
                }
            }
        }
    }
)

if ($violations.Count -gt 0) {
    $details = $violations | ForEach-Object { "$($_.Path) matches '$($_.Pattern)'" }
    throw "Release-facing text contains internal process wording:`n$($details -join [Environment]::NewLine)"
}

Write-Output "Release-facing text hygiene passed for $($files.Count) files."
