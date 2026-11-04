// Big-endian (network order) reads and writes of the protocols' fields: STUN/TURN, SOCKS5, the
// egress probe. (They lived beside the packet tunnel's IP packet codec until 2 November 2026.)

@inline(__always)
func get16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
}

@inline(__always)
func get32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
}

@inline(__always)
func put16(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt16) {
    bytes[offset] = UInt8(value >> 8)
    bytes[offset + 1] = UInt8(value & 0xFF)
}

func be16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }

func be32(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}
