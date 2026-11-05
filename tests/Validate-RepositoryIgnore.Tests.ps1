$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$paths = @('.vs/settings.json', '.idea/workspace.xml', 'project.csproj.user', 'project.suo',
    'project.userprefs', 'TestResults/result.xml', 'src/App/Properties/launchSettings.json',
    'tests/App/Properties/launchSettings.json')

function Assert-GeneratedFilesIgnored {
    param([string] $Root)
    foreach ($path in $paths) {
        & git -C $Root check-ignore --no-index --quiet -- $path
        if ($LASTEXITCODE -ne 0) { throw "Generated IDE artifact is not ignored: $path" }
    }
}

Assert-GeneratedFilesIgnored -Root $repositoryRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "ratespec-ignore-$([Guid]::NewGuid().ToString('N'))"
$previousExitCode = $global:LASTEXITCODE
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    & git -C $testRoot init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize ignore test repository.' }
    $ignore = Get-Content -LiteralPath (Join-Path $repositoryRoot '.gitignore')
    $ignore | Where-Object { $_ -ne '**/Properties/launchSettings.json' } |
        Set-Content -LiteralPath (Join-Path $testRoot '.gitignore')
    $rejected = $false
    try { Assert-GeneratedFilesIgnored -Root $testRoot }
    catch {
        if ($_.Exception.Message -notmatch 'launchSettings\.json') { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'Removing the launch-settings ignore did not fail validation.' }
    Write-Output 'IDE artifact ignores passed, including the missing-pattern negative control.'
}
finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolvedRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Ignore test cleanup path is outside temporary storage.'
    }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    $global:LASTEXITCODE = $previousExitCode
}
