import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Argon2id, version 1.3 (RFC 9106): the memory-hard password KDF the vault uses. Pure Swift, so
/// the core keeps no C dependency; checked bit for bit against the RFC's test vector and the
/// reference implementation's (`Argon2Tests`). Lanes of a slice run in parallel, as in the
/// reference implementation.
enum Argon2id {
    static let version: UInt32 = 0x13
    static let type: UInt64 = 2 // Argon2id
    private static let syncPoints = 4
    private static let wordsPerBlock = 128 // 1024-byte blocks of little-endian 64-bit words

    /// `secret` and `associatedData` are part of Argon2's input (the RFC vector uses them); the
    /// vault passes neither. Inputs must already be in range (`KeyDerivation` checks them).
    static func hash(password: [UInt8], salt: [UInt8], secret: [UInt8] = [], associatedData: [UInt8] = [],
                     passes: Int, memoryKiB: Int, lanes: Int, tagLength: Int) -> [UInt8] {
        precondition(passes >= 1 && lanes >= 1 && memoryKiB >= 8 * lanes && tagLength >= 4)
        // H_0 (RFC 9106 §3.2, figure 1).
        var input = [UInt8]()
        for value in [lanes, tagLength, memoryKiB, passes, Int(version), Int(type)] { input += le32(value) }
        input += le32(password.count) + password + le32(salt.count) + salt
        input += le32(secret.count) + secret + le32(associatedData.count) + associatedData
        var seed = Blake2b.hash(input, outputLength: 64) + [UInt8](repeating: 0, count: 8)
        wipe(&input)
        defer { wipe(&seed) }

        let segmentLength = max(memoryKiB, 2 * syncPoints * lanes) / (lanes * syncPoints)
        let laneLength = segmentLength * syncPoints
        let blockCount = laneLength * lanes
        let words = blockCount * wordsPerBlock
        let memory = UnsafeMutablePointer<UInt64>.allocate(capacity: words)
        memory.initialize(repeating: 0, count: words)
        defer {
            wipe(UnsafeMutableRawPointer(memory), words * 8)
            memory.deallocate()
        }

        // B[i][0] and B[i][1] = H'^1024(H_0 || LE32(j) || LE32(i)).
        for lane in 0..<lanes {
            for column in 0..<2 {
                seed.replaceSubrange(64..<72, with: le32(column) + le32(lane))
                var block = hPrime(seed, 1024)
                load(block, into: memory + (lane * laneLength + column) * wordsPerBlock)
                wipe(&block)
            }
        }

        let instance = Instance(memory: memory, passes: passes, lanes: lanes, laneLength: laneLength,
                                segmentLength: segmentLength, blockCount: blockCount)
        for pass in 0..<passes {
            for slice in 0..<syncPoints {
                // Segments of one slice never reference each other: one lane per thread.
                DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                    fillSegment(instance, pass: pass, lane: lane, slice: slice)
                }
            }
        }

        // C = XOR of the last column; the tag is H'^T(C).
        var last = [UInt64](repeating: 0, count: wordsPerBlock)
        for lane in 0..<lanes {
            let block = memory + (lane * laneLength + laneLength - 1) * wordsPerBlock
            for k in 0..<wordsPerBlock { last[k] ^= block[k] }
        }
        var lastBytes = [UInt8]()
        lastBytes.reserveCapacity(1024)
        for word in last { lastBytes += le64(word) }
        defer { wipe(&lastBytes); for k in last.indices { last[k] = 0 } }
        return hPrime(lastBytes, tagLength)
    }

    // MARK: Memory filling (RFC 9106 §3.2 steps 5-6, §3.4)

    private struct Instance: @unchecked Sendable {
        let memory: UnsafeMutablePointer<UInt64>
        let passes: Int
        let lanes: Int
        let laneLength: Int
        let segmentLength: Int
        let blockCount: Int
    }

    private static func fillSegment(_ instance: Instance, pass: Int, lane: Int, slice: Int) {
        // Scratch: R and its copy for G, the address block, the address generator's input, zero.
        let scratch = UnsafeMutablePointer<UInt64>.allocate(capacity: 5 * wordsPerBlock)
        scratch.initialize(repeating: 0, count: 5 * wordsPerBlock)
        defer {
            wipe(UnsafeMutableRawPointer(scratch), 5 * wordsPerBlock * 8)
            scratch.deallocate()
        }
        let addresses = scratch + 2 * wordsPerBlock
        let addressInput = scratch + 3 * wordsPerBlock
        let zero = scratch + 4 * wordsPerBlock
        let memory = instance.memory

        // Argon2id: data-independent addressing (as Argon2i) in the first half of the first pass.
        let dataIndependent = pass == 0 && slice < syncPoints / 2
        if dataIndependent {
            addressInput[0] = UInt64(pass)
            addressInput[1] = UInt64(lane)
            addressInput[2] = UInt64(slice)
            addressInput[3] = UInt64(instance.blockCount)
            addressInput[4] = UInt64(instance.passes)
            addressInput[5] = type
        }
        func nextAddresses() {
            addressInput[6] &+= 1
            fillBlock(previous: zero, reference: addressInput, next: addresses, withXor: false, scratch: scratch)
            fillBlock(previous: zero, reference: addresses, next: addresses, withXor: false, scratch: scratch)
        }

        var start = 0
        if pass == 0 && slice == 0 {
            start = 2 // the first two blocks of the lane are already there
            if dataIndependent { nextAddresses() }
        }
        var current = lane * instance.laneLength + slice * instance.segmentLength + start
        var previous = current % instance.laneLength == 0 ? current + instance.laneLength - 1 : current - 1

        for index in start..<instance.segmentLength {
            if current % instance.laneLength == 1 { previous = current - 1 }
            let pseudoRandom: UInt64
            if dataIndependent {
                if index % wordsPerBlock == 0 { nextAddresses() }
                pseudoRandom = addresses[index % wordsPerBlock]
            } else {
                pseudoRandom = memory[previous * wordsPerBlock]
            }
            // The first slice of the first pass can only reference its own lane.
            let referenceLane = pass == 0 && slice == 0 ? lane : Int((pseudoRandom >> 32) % UInt64(instance.lanes))
            let referenceIndex = referenceBlock(instance, pass: pass, slice: slice, index: index,
                                                pseudoRandom: pseudoRandom & 0xFFFF_FFFF,
                                                sameLane: referenceLane == lane)
            fillBlock(previous: memory + previous * wordsPerBlock,
                      reference: memory + (referenceLane * instance.laneLength + referenceIndex) * wordsPerBlock,
                      next: memory + current * wordsPerBlock, withXor: pass != 0, scratch: scratch)
            current += 1
            previous += 1
        }
    }

    /// The column z of the reference block (RFC 9106 §3.4.2).
    private static func referenceBlock(_ instance: Instance, pass: Int, slice: Int, index: Int,
                                       pseudoRandom: UInt64, sameLane: Bool) -> Int {
        let area: Int
        if pass == 0 {
            if slice == 0 {
                area = index - 1
            } else {
                area = slice * instance.segmentLength + (sameLane ? index - 1 : (index == 0 ? -1 : 0))
            }
        } else {
            area = instance.laneLength - instance.segmentLength + (sameLane ? index - 1 : (index == 0 ? -1 : 0))
        }
        let x = (pseudoRandom &* pseudoRandom) &>> 32
        let relative = UInt64(area) - 1 - ((UInt64(area) &* x) &>> 32)
        let start = pass == 0 || slice == syncPoints - 1 ? 0 : (slice + 1) * instance.segmentLength
        return (start + Int(relative)) % instance.laneLength
    }

    /// next = G(previous, reference), XORed into next's old value after the first pass (§3.5).
    /// `reference` may be `next` (the address generator); the result is written last.
    @inline(__always)
    private static func fillBlock(previous: UnsafeMutablePointer<UInt64>, reference: UnsafeMutablePointer<UInt64>,
                                  next: UnsafeMutablePointer<UInt64>, withXor: Bool, scratch: UnsafeMutablePointer<UInt64>) {
        let r = scratch
        let saved = scratch + wordsPerBlock
        for k in 0..<wordsPerBlock { r[k] = reference[k] ^ previous[k] }
        if withXor {
            for k in 0..<wordsPerBlock { saved[k] = r[k] ^ next[k] }
        } else {
            for k in 0..<wordsPerBlock { saved[k] = r[k] }
        }
        for i in 0..<8 { // rows: 16 consecutive words
            let b = 16 * i
            permute(r, b, b + 1, b + 2, b + 3, b + 4, b + 5, b + 6, b + 7,
                    b + 8, b + 9, b + 10, b + 11, b + 12, b + 13, b + 14, b + 15)
        }
        for i in 0..<8 { // columns: pairs of words, 16 apart
            let b = 2 * i
            permute(r, b, b + 1, b + 16, b + 17, b + 32, b + 33, b + 48, b + 49,
                    b + 64, b + 65, b + 80, b + 81, b + 96, b + 97, b + 112, b + 113)
        }
        for k in 0..<wordsPerBlock { next[k] = saved[k] ^ r[k] }
    }

    /// The permutation P: one BLAKE2b round without message, with BlaMka's multiplications (§3.6).
    @inline(__always)
    private static func permute(_ v: UnsafeMutablePointer<UInt64>, _ i0: Int, _ i1: Int, _ i2: Int, _ i3: Int,
                                _ i4: Int, _ i5: Int, _ i6: Int, _ i7: Int, _ i8: Int, _ i9: Int, _ i10: Int,
                                _ i11: Int, _ i12: Int, _ i13: Int, _ i14: Int, _ i15: Int) {
        var v0 = v[i0], v1 = v[i1], v2 = v[i2], v3 = v[i3], v4 = v[i4], v5 = v[i5], v6 = v[i6], v7 = v[i7]
        var v8 = v[i8], v9 = v[i9], v10 = v[i10], v11 = v[i11], v12 = v[i12], v13 = v[i13], v14 = v[i14], v15 = v[i15]
        gb(&v0, &v4, &v8, &v12); gb(&v1, &v5, &v9, &v13); gb(&v2, &v6, &v10, &v14); gb(&v3, &v7, &v11, &v15)
        gb(&v0, &v5, &v10, &v15); gb(&v1, &v6, &v11, &v12); gb(&v2, &v7, &v8, &v13); gb(&v3, &v4, &v9, &v14)
        v[i0] = v0; v[i1] = v1; v[i2] = v2; v[i3] = v3; v[i4] = v4; v[i5] = v5; v[i6] = v6; v[i7] = v7
        v[i8] = v8; v[i9] = v9; v[i10] = v10; v[i11] = v11; v[i12] = v12; v[i13] = v13; v[i14] = v14; v[i15] = v15
    }

    @inline(__always)
    private static func gb(_ a: inout UInt64, _ b: inout UInt64, _ c: inout UInt64, _ d: inout UInt64) {
        a = blamka(a, b); d = rotateRight(d ^ a, 32)
        c = blamka(c, d); b = rotateRight(b ^ c, 24)
        a = blamka(a, b); d = rotateRight(d ^ a, 16)
        c = blamka(c, d); b = rotateRight(b ^ c, 63)
    }

    @inline(__always)
    private static func blamka(_ x: UInt64, _ y: UInt64) -> UInt64 {
        x &+ y &+ (((x & 0xFFFF_FFFF) &* (y & 0xFFFF_FFFF)) &<< 1)
    }

    // MARK: H' (RFC 9106 §3.3)

    static func hPrime(_ input: [UInt8], _ length: Int) -> [UInt8] {
        let prefixed = le32(length) + input
        if length <= 64 { return Blake2b.hash(prefixed, outputLength: length) }
        var output = [UInt8]()
        output.reserveCapacity(length)
        var v = Blake2b.hash(prefixed, outputLength: 64)
        output += v[0..<32]
        var remaining = length - 32
        while remaining > 64 {
            v = Blake2b.hash(v, outputLength: 64)
            output += v[0..<32]
            remaining -= 32
        }
        output += Blake2b.hash(v, outputLength: remaining)
        wipe(&v)
        return output
    }

    private static func load(_ bytes: [UInt8], into block: UnsafeMutablePointer<UInt64>) {
        for i in 0..<wordsPerBlock {
            var word: UInt64 = 0
            for k in 0..<8 { word |= UInt64(bytes[8 * i + k]) << (8 * UInt64(k)) }
            block[i] = word
        }
    }
}

/// BLAKE2b (RFC 7693), unkeyed, 1–64-byte digests: Argon2's hash H.
enum Blake2b {
    private static let iv: [UInt64] = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    ]
    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    static func hash(_ input: [UInt8], outputLength: Int) -> [UInt8] {
        precondition((1...64).contains(outputLength))
        var h = iv
        h[0] ^= 0x0101_0000 ^ UInt64(outputLength)
        var counter: UInt64 = 0
        var offset = 0
        while input.count - offset > 128 {
            counter += 128
            compress(&h, input, offset, counter, last: false)
            offset += 128
        }
        var block = [UInt8](repeating: 0, count: 128)
        block.replaceSubrange(0..<(input.count - offset), with: input[offset...])
        counter += UInt64(input.count - offset)
        compress(&h, block, 0, counter, last: true)
        wipe(&block)
        var output = [UInt8]()
        output.reserveCapacity(64)
        for word in h { output += le64(word) }
        return Array(output.prefix(outputLength))
    }

    private static func compress(_ h: inout [UInt64], _ bytes: [UInt8], _ offset: Int, _ counter: UInt64, last: Bool) {
        var m = [UInt64](repeating: 0, count: 16)
        for i in 0..<16 {
            var word: UInt64 = 0
            for k in 0..<8 { word |= UInt64(bytes[offset + 8 * i + k]) << (8 * UInt64(k)) }
            m[i] = word
        }
        var v = h + iv
        v[12] ^= counter // messages here are far shorter than 2^64 bytes: the high word stays 0
        if last { v[14] = ~v[14] }
        for round in 0..<12 {
            let s = sigma[round % 10]
            mix(&v, 0, 4, 8, 12, m[s[0]], m[s[1]])
            mix(&v, 1, 5, 9, 13, m[s[2]], m[s[3]])
            mix(&v, 2, 6, 10, 14, m[s[4]], m[s[5]])
            mix(&v, 3, 7, 11, 15, m[s[6]], m[s[7]])
            mix(&v, 0, 5, 10, 15, m[s[8]], m[s[9]])
            mix(&v, 1, 6, 11, 12, m[s[10]], m[s[11]])
            mix(&v, 2, 7, 8, 13, m[s[12]], m[s[13]])
            mix(&v, 3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for i in 0..<8 { h[i] ^= v[i] ^ v[i + 8] }
        for i in m.indices { m[i] = 0 }
    }

    @inline(__always)
    private static func mix(_ v: inout [UInt64], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
        v[a] = v[a] &+ v[b] &+ x; v[d] = rotateRight(v[d] ^ v[a], 32)
        v[c] = v[c] &+ v[d]; v[b] = rotateRight(v[b] ^ v[c], 24)
        v[a] = v[a] &+ v[b] &+ y; v[d] = rotateRight(v[d] ^ v[a], 16)
        v[c] = v[c] &+ v[d]; v[b] = rotateRight(v[b] ^ v[c], 63)
    }
}

@inline(__always)
private func rotateRight(_ x: UInt64, _ n: UInt64) -> UInt64 { (x &>> n) | (x &<< (64 - n)) }

private func le32(_ value: Int) -> [UInt8] {
    let v = UInt32(truncatingIfNeeded: value)
    return [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8),
            UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)]
}

private func le64(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
}

/// Overwrites key material before its memory is released: `memset_s` on Apple platforms, which the
/// compiler may not remove. Elsewhere (the Linux CI build) a plain overwrite, best effort.
func wipe(_ pointer: UnsafeMutableRawPointer, _ count: Int) {
    guard count > 0 else { return }
    #if canImport(Darwin)
    _ = memset_s(pointer, count, 0, count)
    #else
    memset(pointer, 0, count)
    #endif
}

func wipe(_ bytes: inout [UInt8]) {
    bytes.withUnsafeMutableBytes { buffer in
        if let base = buffer.baseAddress { wipe(base, buffer.count) }
    }
}

func wipe(_ data: inout Data) {
    data.withUnsafeMutableBytes { buffer in
        if let base = buffer.baseAddress { wipe(base, buffer.count) }
    }
}
