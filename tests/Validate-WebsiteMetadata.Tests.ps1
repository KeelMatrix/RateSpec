$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../build/Invoke-NestedPwsh.ps1')
$validator = Join-Path $PSScriptRoot '../scripts/Validate-WebsiteMetadata.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "ratespec-metadata-$([Guid]::NewGuid().ToString('N'))"
$url = 'https://github.com/KeelMatrix/RateSpec'
$tags = 'testing;http;keelmatrix-public-product;keelmatrix-primary'
$manifest = '{"schemaVersion":1,"packages":{"KeelMatrix.RateSpec":{"visibility":"public-product","role":"primary"}}}'
$passed = 0

function Write-Manifest([string] $Text = $manifest) {
    [IO.File]::WriteAllText((Join-Path $testRoot 'keelmatrix.website.json'), $Text)
}
function Write-Source([string] $Tags = $tags, [string] $ProjectUrl = $url, [string] $RepositoryUrl = $url,
    [string] $RepositoryType = 'git', [string] $Id = 'KeelMatrix.RateSpec', [string] $Packable = 'true') {
    $properties = @{ IsPackable = $Packable; PackageId = $Id; PackageTags = $Tags; PackageProjectUrl = $ProjectUrl;
        RepositoryUrl = $RepositoryUrl; RepositoryType = $RepositoryType }
    $xml = '<Project><PropertyGroup>'
    foreach ($name in $properties.Keys) { $xml += "<$name>$([Security.SecurityElement]::Escape($properties[$name]))</$name>" }
    $xml += '</PropertyGroup></Project>'
    [IO.File]::WriteAllText((Join-Path $testRoot 'metadata.props'), $xml)
}
function Get-Nuspec([string] $Tags = $tags, [string] $ProjectUrl = $url, [string] $RepositoryUrl = $url,
    [string] $RepositoryType = 'git', [string] $Id = 'KeelMatrix.RateSpec') {
    '<package xmlns="http://schemas.microsoft.com/packaging/2013/05/nuspec.xsd"><metadata>' +
        "<id>$Id</id><tags>$Tags</tags><projectUrl>$ProjectUrl</projectUrl>" +
        "<repository type=`"$RepositoryType`" url=`"$RepositoryUrl`" /></metadata></package>"
}
function Write-Package([string] $Path, [string] $Text) {
    $stream = [IO.File]::Create($Path)
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $writer = [IO.StreamWriter]::new($zip.CreateEntry('KeelMatrix.RateSpec.nuspec').Open())
        try { $writer.Write($Text) } finally { $writer.Dispose() }
    }
    finally { $zip.Dispose(); $stream.Dispose() }
}
function Assert-Accepted([hashtable] $Arguments = @{}) {
    & $validator -RepositoryRoot $testRoot @Arguments | Out-Null
    $script:passed++
}
function Assert-Rejected([string] $Name, [string] $Message, [hashtable] $Arguments = @{}) {
    $errorText = $null
    try { & $validator -RepositoryRoot $testRoot @Arguments | Out-Null }
    catch { $errorText = $_.Exception.Message }
    if ($null -eq $errorText -or $errorText -notmatch $Message) { throw "$Name did not fail as expected ($Message): $errorText" }
    $script:passed++
}

New-Item -ItemType Directory -Path $testRoot | Out-Null
$previousExitCode = $global:LASTEXITCODE
try {
    # Real MSBuild evaluation, including inherited properties; no SDK, restore or compilation is needed.
    [IO.File]::WriteAllText((Join-Path $testRoot 'fixture.csproj'), '<Project><Import Project="metadata.props" /></Project>')
    Write-Source
    Assert-Rejected 'missing manifest' 'Missing keelmatrix.website.json'
    $manifestCases = @(
        @('{', 'JSON'), @('[]', 'must be an object'), @('{}', 'missing'),
        @($manifest.Replace('"schemaVersion":1', '"schemaVersion":1,"schemaVersion":1'), 'duplicate'),
        @($manifest.Replace('"schemaVersion":1', '"SchemaVersion":1'), 'unexpected'),
        @($manifest.Replace('"schemaVersion":1,', ''), 'missing'),
        @($manifest.Replace('"schemaVersion":1', '"schemaVersion":2'), 'integer 1'),
        @($manifest.Replace('"schemaVersion":1', '"schemaVersion":"1"'), 'integer 1'),
        @($manifest.Replace('"schemaVersion":1', '"schemaVersion":1.0'), 'integer 1'),
        @($manifest.Replace('"schemaVersion":1', '"schemaVersion":null'), 'integer 1'),
        @($manifest.Replace('"schemaVersion":1', '"schemaVersion":1,"url":"extra"'), 'unexpected'),
        @('{"schemaVersion":1,"packages":[]}', 'must be an object'),
        @('{"schemaVersion":1,"packages":{}}', 'exactly one primary'),
        @($manifest.Replace('"role":"primary"', '"role":"primary","role":"component"'), 'duplicate'),
        @($manifest.Replace('"visibility":"public-product",', ''), 'missing'),
        @($manifest.Replace('"role":"primary"', '"Role":"primary"'), 'unexpected'),
        @($manifest.Replace('"primary"', '"Primary"'), 'invalid'),
        @($manifest.Replace('"public-product"', '"Public-Product"'), 'invalid'),
        @($manifest.Replace('"public-product"', 'null'), 'invalid'),
        @($manifest.Replace('"primary"', 'false'), 'invalid'),
        @($manifest.Replace('"primary"', '"component"'), 'exactly one primary'),
        @($manifest.Replace('"public-product"', '"internal-package"'), 'exactly one primary'),
        @($manifest.Replace('KeelMatrix.RateSpec', 'Other.Package'), 'no exact manifest entry'),
        @($manifest.Replace('KeelMatrix.RateSpec', 'keelmatrix.ratespec'), 'no exact manifest entry'),
        @($manifest.Replace('KeelMatrix.RateSpec', 'Invalid ID'), 'IDs must be valid'),
        @($manifest.Replace('"packages":{', '"packages":{"KeelMatrix.RateSpec":{"visibility":"public-product","role":"component"},'), 'unique'),
        @($manifest.Replace('"packages":{', '"packages":{"keelmatrix.ratespec":{"visibility":"public-product","role":"component"},'), 'unique'),
        @($manifest.Replace('"packages":{', '"packages":{"Other.Package":{"visibility":"public-product","role":"primary"},'), 'exactly one primary'),
        @($manifest.Replace('"packages":{', '"packages":{"Other.Package":{"visibility":"public-product","role":"component"},'), 'no exact packable source')
    )
    foreach ($case in $manifestCases) {
        Write-Manifest $case[0]
        Assert-Rejected 'manifest fixture' $case[1]
    }
    Write-Manifest
    Assert-Accepted
    Write-Source -Id 'keelmatrix.ratespec'
    Assert-Rejected 'source ID casing' 'no exact manifest entry'
    Write-Source -Packable false
    Assert-Rejected 'nonpackable manifest entry' 'no exact packable source'
    Write-Source
    [IO.File]::WriteAllText((Join-Path $testRoot 'duplicate.csproj'), '<Project><Import Project="metadata.props" /></Project>')
    Assert-Rejected 'duplicate source IDs' 'IDs must be nonempty and unique'
    Remove-Item -LiteralPath (Join-Path $testRoot 'duplicate.csproj')

    $package = Join-Path $testRoot 'fixture.nupkg'
    $symbols = Join-Path $testRoot 'fixture.snupkg'
    Write-Package $package (Get-Nuspec)
    Write-Package $symbols (Get-Nuspec)
    Assert-Accepted @{ PackagePath = $package; SymbolPackagePath = $symbols }
    # All invalid sentinel classes apply equally to evaluated source and either archive.
    $badTags = @('testing', 'testing;keelmatrix-primary', 'testing;keelmatrix-public-product')
    foreach ($sentinel in @('keelmatrix-public-product', 'keelmatrix-primary')) {
        $opposite = if ($sentinel -like '*public*') { 'keelmatrix-internal-package' } else { 'keelmatrix-component' }
        $badTags += $tags.Replace($sentinel, $opposite)
        $badTags += "$tags;$sentinel"
        $badTags += "$tags;$opposite"
        $badTags += $tags.Replace($sentinel, $sentinel.ToUpperInvariant())
        $badTags += "$tags;$($sentinel.ToUpperInvariant())"
        $badTags += "$tags;${sentinel}x"
    }
    foreach ($bad in $badTags) {
        Write-Source -Tags $bad
        Assert-Rejected 'source sentinel fixture' 'sentinel'
        Write-Source
        foreach ($side in @($package, $symbols)) {
            Write-Package $side (Get-Nuspec -Tags $bad)
            Assert-Rejected 'built sentinel fixture' 'sentinel' @{ PackagePath = $package; SymbolPackagePath = $symbols }
            Write-Package $side (Get-Nuspec)
        }
    }
    # Canonical URL equality excludes alternate schemes/hosts/owners/paths and disguised suffixes.
    $badUrls = @('', 'http://github.com/KeelMatrix/RateSpec', 'https://github.com.evil/KeelMatrix/RateSpec',
        'https://github.com@evil/KeelMatrix/RateSpec', 'https://github.com/Other/RateSpec',
        'https://github.com/KeelMatrix/Other', 'https://github.com/keelmatrix/RateSpec',
        "$url/", "$url.git", "${url}?x=1", "${url}#fragment")
    foreach ($bad in $badUrls) {
        foreach ($property in @('ProjectUrl', 'RepositoryUrl')) {
            $arguments = @{ $property = $bad }
            Write-Source @arguments
            Assert-Rejected 'source URL fixture' 'canonical'
            Write-Source
            foreach ($side in @($package, $symbols)) {
                Write-Package $side (Get-Nuspec @arguments)
                Assert-Rejected 'built URL fixture' 'canonical' @{ PackagePath = $package; SymbolPackagePath = $symbols }
                Write-Package $side (Get-Nuspec)
            }
        }
    }
    Write-Source -RepositoryType svn
    Assert-Rejected 'source repository type' 'canonical'
    Write-Source
    $builtCases = @(
        @((Get-Nuspec -RepositoryType svn), 'canonical'),
        @((Get-Nuspec -Id 'keelmatrix.ratespec'), 'no exact manifest entry'),
        @((Get-Nuspec -Tags "$tags;extra"), 'tags disagree'),
        @((Get-Nuspec).Replace('<tags>', '<tags>duplicate</tags><tags>'), "exactly one 'tags'"),
        @(((Get-Nuspec) -replace '<tags>.*?</tags>', ''), "exactly one 'tags'"),
        @((Get-Nuspec).Replace('<id>', '<id>Other</id><id>'), "exactly one 'id'"),
        @((Get-Nuspec).Replace('<projectUrl>', '<projectUrl>Other</projectUrl><projectUrl>'), "exactly one 'projectUrl'"),
        @((Get-Nuspec).Replace('<repository ', '<repository type="git" url="other" /><repository '), "exactly one 'repository'")
    )
    foreach ($case in $builtCases) {
        foreach ($side in @($package, $symbols)) {
            Write-Package $side $case[0]
            Assert-Rejected 'built metadata fixture' $case[1] @{ PackagePath = $package; SymbolPackagePath = $symbols }
            Write-Package $side (Get-Nuspec)
        }
    }
    # Additional siblings must be declared, and only one public primary may exist.
    $sibling = '"KeelMatrix.RateSpec.Extra":{"visibility":"public-product","role":"component"},'
    Write-Manifest ($manifest.Replace('"packages":{', '"packages":{' + $sibling))
    [IO.File]::WriteAllText((Join-Path $testRoot 'sibling.csproj'), '<Project><Import Project="metadata.props" /><PropertyGroup><PackageId>KeelMatrix.RateSpec.Extra</PackageId><PackageTags>keelmatrix-public-product;keelmatrix-component</PackageTags></PropertyGroup></Project>')
    Assert-Accepted
    Write-Manifest
    Assert-Rejected 'undeclared packable sibling' 'no exact manifest entry'
    Remove-Item -LiteralPath (Join-Path $testRoot 'sibling.csproj')
    # A Release-only override must not be hidden by the inherited Debug/default metadata.
    [IO.File]::WriteAllText((Join-Path $testRoot 'fixture.csproj'), '<Project><Import Project="metadata.props" /><PropertyGroup Condition="''$(Configuration)'' == ''Release''"><PackageTags>testing</PackageTags></PropertyGroup></Project>')
    Assert-Rejected 'Release metadata override' 'sentinel'
    # Prove the script also fails as a native child process, as used by local/CI/release validation.
    $output = Invoke-NestedPwsh -NoProfile -File $validator -RepositoryRoot $testRoot 2>&1
    if ($LASTEXITCODE -eq 0 -or ($output | Out-String) -notmatch 'sentinel') { throw 'Native metadata failure did not propagate.' }
    function dotnet { $global:LASTEXITCODE = 37; '{}' }
    Assert-Rejected 'MSBuild failure' 'MSBuild metadata evaluation failed.*exit code 37'
    Remove-Item Function:\dotnet
    Write-Output "Website metadata regressions passed: $passed fixtures plus native failure propagation."
}
finally {
    $global:LASTEXITCODE = $previousExitCode
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolved.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notlike 'ratespec-metadata-*') { throw 'Unsafe metadata fixture cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
