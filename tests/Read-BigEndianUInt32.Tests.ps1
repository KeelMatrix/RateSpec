$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../build/Read-BigEndianUInt32.ps1')

# Numeric buffers exercise the decoder without creating image assets.
$values = @('0', '1', '255', '256', '511', '512', '513', '65535', '65536',
    '16777215', '16777216', '2147483647', '2147483648', '4294967295')
foreach ($value in $values) {
    $expected = [uint32]::Parse($value)
    $bytes = [BitConverter]::GetBytes($expected)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    foreach ($offset in @(0, 3)) {
        $buffer = [byte[]](@(7) * $offset + $bytes + @(9, 10))
        $actual = Read-BigEndianUInt32 -Bytes $buffer -Offset $offset
        if ($actual -isnot [uint32] -or $actual -ne $expected) {
            throw "Decoded $value at offset $offset as $actual ($($actual.GetType().Name))."
        }
    }
}

foreach ($offset in @(-1, 1, [int]::MaxValue)) {
    $rejected = $false
    try { Read-BigEndianUInt32 -Bytes ([byte[]](1, 2, 3, 4)) -Offset $offset | Out-Null }
    catch { $rejected = $true }
    if (-not $rejected) { throw "Invalid offset $offset was accepted." }
}
foreach ($length in @(0, 1, 2, 3)) {
    $rejected = $false
    try { Read-BigEndianUInt32 -Bytes ([byte[]](@(1) * $length)) | Out-Null }
    catch { $rejected = $true }
    if (-not $rejected) { throw "Truncated $length-byte integer was accepted." }
}
Write-Output 'Big-endian UInt32 decoding passed: 28 value/offset cases and 7 invalid ranges.'
