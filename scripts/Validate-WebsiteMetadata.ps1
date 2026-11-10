#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $PackagePath,
    [string] $SymbolPackagePath
)

$ErrorActionPreference = 'Stop'
$canonicalUrl = 'https://github.com/KeelMatrix/RateSpec'

function Assert-ObjectShape($Element, [string[]] $Names, [string] $Context) {
    if ($Element.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw "$Context must be an object." }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($property in $Element.EnumerateObject()) {
        if (-not $seen.Add($property.Name)) { throw "$Context has a duplicate property '$($property.Name)'." }
        if ($Names -cnotcontains $property.Name) { throw "$Context has an unexpected property '$($property.Name)'." }
    }
    foreach ($name in $Names) {
        if (-not $seen.Contains($name)) { throw "$Context is missing '$name'." }
    }
}

function Get-ProjectFiles([string] $Directory) {
    foreach ($file in Get-ChildItem -LiteralPath $Directory -File) {
        if ($file.Extension -in @('.csproj', '.fsproj', '.vbproj')) { $file }
    }
    foreach ($child in Get-ChildItem -LiteralPath $Directory -Directory) {
        if ($child.Name -notin @('bin', 'obj', 'artifacts', '.git')) { Get-ProjectFiles $child.FullName }
    }
}

function Get-TagTokens([string] $Tags) {
    # MSBuild PackageTags uses semicolons; NuGet writes space-delimited nuspec tags.
    @($Tags -split '[;\s]+' | Where-Object { $_.Length -gt 0 })
}

function Assert-Classification([string] $Id, [string] $Tags, [string] $ProjectUrl, [string] $RepositoryUrl, [string] $RepositoryType) {
    if (-not $classifications.ContainsKey($Id)) { throw "Package '$Id' has no exact manifest entry." }
    $entry = $classifications[$Id]
    $tokens = @(Get-TagTokens $Tags)
    $visibility = @($tokens | Where-Object { $_ -in @('keelmatrix-public-product', 'keelmatrix-internal-package') })
    $role = @($tokens | Where-Object { $_ -in @('keelmatrix-primary', 'keelmatrix-component') })
    if ($visibility.Count -ne 1 -or $visibility[0] -cne "keelmatrix-$($entry.Visibility)" -or
        $role.Count -ne 1 -or $role[0] -cne "keelmatrix-$($entry.Role)" -or
        @($tokens | Where-Object { $_ -imatch '^keelmatrix-' -and $_ -cnotin @('keelmatrix-public-product', 'keelmatrix-internal-package', 'keelmatrix-primary', 'keelmatrix-component') }).Count -gt 0) {
        throw "Package '$Id' must have exactly one matching lowercase visibility and role sentinel."
    }
    if ($ProjectUrl -cne $canonicalUrl -or $RepositoryUrl -cne $canonicalUrl -or $RepositoryType -cne 'git') {
        throw "Package '$Id' must use canonical project/repository URLs '$canonicalUrl' and repository type 'git'."
    }
}

$root = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$manifestPath = Join-Path $root 'keelmatrix.website.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Missing keelmatrix.website.json.' }
$document = [System.Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($manifestPath))
$classifications = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
try {
    $manifest = $document.RootElement
    Assert-ObjectShape $manifest @('schemaVersion', 'packages') 'Manifest root'
    if ($manifest.GetProperty('schemaVersion').GetRawText() -cne '1') { throw 'Manifest schemaVersion must be the integer 1.' }
    $packages = $manifest.GetProperty('packages')
    if ($packages.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw 'Manifest packages must be an object.' }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($package in $packages.EnumerateObject()) {
        if ($package.Name -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$' -or -not $ids.Add($package.Name)) {
            throw 'Manifest package IDs must be valid and unique, including casing variants.'
        }
        Assert-ObjectShape $package.Value @('visibility', 'role') "Manifest package '$($package.Name)'"
        $visibility = $package.Value.GetProperty('visibility')
        $role = $package.Value.GetProperty('role')
        if ($visibility.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
            $role.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
            $visibility.GetString() -cnotin @('public-product', 'internal-package') -or
            $role.GetString() -cnotin @('primary', 'component')) { throw 'Manifest visibility or role is invalid.' }
        $classifications.Add($package.Name, [pscustomobject]@{ Visibility = $visibility.GetString(); Role = $role.GetString() })
    }
    if (@($classifications.Values | Where-Object Role -CEQ 'primary').Count -ne 1 -or
        @($classifications.Values | Where-Object { $_.Role -ceq 'primary' -and $_.Visibility -ceq 'public-product' }).Count -ne 1) {
        throw 'Manifest must have exactly one primary package, classified as public-product.'
    }
}
finally { $document.Dispose() }

$source = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
$sourceIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($project in Get-ProjectFiles $root) {
    $output = & dotnet msbuild $project.FullName -nologo -property:Configuration=Release `
        -getProperty:IsPackable,PackageId,PackageTags,PackageProjectUrl,RepositoryUrl,RepositoryType
    if ($LASTEXITCODE -ne 0) { throw "MSBuild metadata evaluation failed for '$($project.Name)' with exit code $LASTEXITCODE." }
    $properties = ($output -join "`n" | ConvertFrom-Json).Properties
    if ($properties.IsPackable -ieq 'false') { continue }
    if ($properties.IsPackable -ine 'true') { throw "Project '$($project.Name)' has invalid IsPackable metadata." }
    $id = $properties.PackageId
    if ([string]::IsNullOrWhiteSpace($id) -or -not $sourceIds.Add($id)) { throw 'Packable source package IDs must be nonempty and unique.' }
    Assert-Classification $id $properties.PackageTags $properties.PackageProjectUrl $properties.RepositoryUrl $properties.RepositoryType
    $source.Add($id, $properties)
}
foreach ($id in $classifications.Keys) {
    if (-not $source.ContainsKey($id)) { throw "Manifest package '$id' has no exact packable source project." }
}

foreach ($path in @($PackagePath, $SymbolPackagePath) | Where-Object { $_ }) {
    $zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $path).Path)
    try {
        $nuspecs = @($zip.Entries | Where-Object { $_.FullName -cmatch '^[^/]+\.nuspec$' })
        if ($nuspecs.Count -ne 1) { throw 'Built package must contain exactly one root nuspec.' }
        $reader = [IO.StreamReader]::new($nuspecs[0].Open())
        try { $xml = [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
        $ns = [Xml.XmlNamespaceManager]::new($xml.NameTable)
        $ns.AddNamespace('n', 'http://schemas.microsoft.com/packaging/2013/05/nuspec.xsd')
        $nodes = @($xml.SelectNodes('/n:package/n:metadata', $ns))
        if ($nodes.Count -ne 1) { throw 'Built package metadata is missing or ambiguous.' }
        $metadata = $nodes[0]
        foreach ($name in @('id', 'tags', 'projectUrl', 'repository')) {
            if (@($metadata.SelectNodes("n:$name", $ns)).Count -ne 1) { throw "Built package requires exactly one '$name' element." }
        }
        $id = [string]$metadata.id
        Assert-Classification $id $metadata.tags $metadata.projectUrl $metadata.repository.url $metadata.repository.type
        if (-not $source.ContainsKey($id)) { throw "Built package '$id' has no exact packable source project." }
        $sourceTags = @(Get-TagTokens $source[$id].PackageTags | Sort-Object -CaseSensitive)
        $builtTags = @(Get-TagTokens $metadata.tags | Sort-Object -CaseSensitive)
        if (($sourceTags -join "`n") -cne ($builtTags -join "`n")) { throw "Built package '$id' tags disagree with evaluated source." }
    }
    finally { $zip.Dispose() }
}
Write-Output "Website metadata is valid for $($source.Count) packable project(s)."
