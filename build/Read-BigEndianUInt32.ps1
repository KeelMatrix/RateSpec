function Read-BigEndianUInt32 {
    param(
        [Parameter(Mandatory)] [byte[]] $Bytes,
        [ValidateRange(0, [int]::MaxValue)] [int] $Offset = 0
    )

    if ($Offset -gt ($Bytes.Length - 4)) {
        throw 'A big-endian UInt32 requires four bytes at the specified offset.'
    }

    # Widen before shifting: a byte operand discards the high-order bits.
    return [uint32](
        ([uint32]$Bytes[$Offset] -shl 24) -bor
        ([uint32]$Bytes[$Offset + 1] -shl 16) -bor
        ([uint32]$Bytes[$Offset + 2] -shl 8) -bor $Bytes[$Offset + 3])
}
