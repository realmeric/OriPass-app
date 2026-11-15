import Foundation

/// Argon2id, version 0x13 (RFC 9106), which no Apple framework has. The
/// memory is one allocation of 1 KiB blocks, lane after lane; within a
/// slice the lanes are filled side by side, one thread each.
enum Argon2id {
    private static let blockWords = 128

    static func hash(password: UnsafeRawBufferPointer, salt: Data, iterations: Int, memoryKiB: Int,
                     parallelism: Int, secret: Data = Data(), associated: Data = Data(), length: Int = 32) throws -> Data {
        guard iterations >= 1, parallelism >= 1, memoryKiB >= 8 * parallelism else { throw CryptoError.badKey }
        let lanes = parallelism
        let laneLength = memoryKiB / (4 * lanes) * 4
        let segment = laneLength / 4

        var h0 = Blake2b()
        for word in [lanes, length, memoryKiB, iterations, 0x13, 2] { h0.update(UInt32(word)) }
        h0.update(UInt32(password.count)); h0.update(Data(password))
        h0.update(UInt32(salt.count)); h0.update(salt)
        h0.update(UInt32(secret.count)); h0.update(secret)
        h0.update(UInt32(associated.count)); h0.update(associated)
        let seed = h0.finish()

        let memory = Memory(blocks: lanes * laneLength)
        defer { memory.release() }
        for lane in 0..<lanes {
            for column in 0..<2 {
                var input = seed
                input.append(contentsOf: le32(column) + le32(lane))
                memory.write(long(input, length: 1024), at: lane * laneLength + column)
            }
        }

        for pass in 0..<iterations {
            for slice in 0..<4 {
                DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                    fill(memory, pass: pass, slice: slice, lane: lane, lanes: lanes, laneLength: laneLength,
                         segment: segment, iterations: iterations)
                }
            }
        }

        var last = [UInt64](repeating: 0, count: blockWords)
        for lane in 0..<lanes {
            let block = memory.block(lane * laneLength + laneLength - 1)
            for i in 0..<blockWords { last[i] ^= block[i] }
        }
        var bytes = Data(capacity: 1024)
        for word in last { withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) } }
        return long(bytes, length: length)
    }

    private static func fill(_ memory: Memory, pass: Int, slice: Int, lane: Int, lanes: Int,
                             laneLength: Int, segment: Int, iterations: Int) {
        let independent = pass == 0 && slice < 2
        let scratch = Scratch()
        defer { scratch.release() }
        if independent {
            let input = scratch.input
            input[0] = UInt64(pass); input[1] = UInt64(lane); input[2] = UInt64(slice)
            input[3] = UInt64(lanes * laneLength); input[4] = UInt64(iterations); input[5] = 2
        }
        func nextAddresses() {
            scratch.input[6] &+= 1
            compress(scratch.zero, scratch.input, into: scratch.once, scratch)
            compress(scratch.zero, scratch.once, into: scratch.addresses, scratch)
        }
        let first = pass == 0 && slice == 0 ? 2 : 0
        if independent && first == 2 { nextAddresses() }
        for index in first..<segment {
            let column = slice * segment + index
            let current = lane * laneLength + column
            let previous = column == 0 ? current + laneLength - 1 : current - 1
            let pseudo: UInt64
            if independent {
                if index % blockWords == 0 { nextAddresses() }
                pseudo = scratch.addresses[index % blockWords]
            } else {
                pseudo = memory.block(previous)[0]
            }
            let j1 = pseudo & 0xffff_ffff
            let j2 = pseudo >> 32
            let refLane = pass == 0 && slice == 0 ? lane : Int(j2 % UInt64(lanes))
            let sameLane = refLane == lane
            let area: Int
            if pass == 0 {
                area = sameLane ? slice * segment + index - 1 : slice * segment - (index == 0 ? 1 : 0)
            } else {
                area = sameLane ? laneLength - segment + index - 1 : laneLength - segment - (index == 0 ? 1 : 0)
            }
            let x = (j1 &* j1) >> 32
            let y = (UInt64(area) &* x) >> 32
            let z = UInt64(area) - 1 - y
            let start = pass == 0 || slice == 3 ? 0 : (slice + 1) * segment
            let reference = refLane * laneLength + (start + Int(z)) % laneLength
            let target = memory.block(current)
            if pass > 0 {
                compress(memory.block(previous), memory.block(reference), into: scratch.result, scratch)
                for i in 0..<blockWords { target[i] ^= scratch.result[i] }
            } else {
                compress(memory.block(previous), memory.block(reference), into: target, scratch)
            }
        }
    }

    /// G: the two blocks XORed, the permutation over the rows and then the
    /// columns, and the XOR added back.
    @inline(__always)
    private static func compress(_ x: UnsafeMutableBufferPointer<UInt64>, _ y: UnsafeMutableBufferPointer<UInt64>,
                                 into out: UnsafeMutableBufferPointer<UInt64>, _ scratch: Scratch) {
        let r = scratch.r, q = scratch.q
        for i in 0..<blockWords { r[i] = x[i] ^ y[i]; q[i] = r[i] }
        let v = q.baseAddress!
        for row in 0..<8 {
            let b = row * 16
            permute(v, b, b + 1, b + 2, b + 3, b + 4, b + 5, b + 6, b + 7,
                    b + 8, b + 9, b + 10, b + 11, b + 12, b + 13, b + 14, b + 15)
        }
        for col in 0..<8 {
            let b = col * 2
            permute(v, b, b + 1, b + 16, b + 17, b + 32, b + 33, b + 48, b + 49,
                    b + 64, b + 65, b + 80, b + 81, b + 96, b + 97, b + 112, b + 113)
        }
        for i in 0..<blockWords { out[i] = q[i] ^ r[i] }
    }

    @inline(__always)
    private static func permute(_ v: UnsafeMutablePointer<UInt64>, _ i0: Int, _ i1: Int, _ i2: Int, _ i3: Int, _ i4: Int,
                                _ i5: Int, _ i6: Int, _ i7: Int, _ i8: Int, _ i9: Int, _ i10: Int, _ i11: Int,
                                _ i12: Int, _ i13: Int, _ i14: Int, _ i15: Int) {
        gb(v, i0, i4, i8, i12); gb(v, i1, i5, i9, i13); gb(v, i2, i6, i10, i14); gb(v, i3, i7, i11, i15)
        gb(v, i0, i5, i10, i15); gb(v, i1, i6, i11, i12); gb(v, i2, i7, i8, i13); gb(v, i3, i4, i9, i14)
    }

    @inline(__always)
    private static func gb(_ v: UnsafeMutablePointer<UInt64>, _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        @inline(__always) func mul(_ x: UInt64, _ y: UInt64) -> UInt64 { 2 &* (x & 0xffff_ffff) &* (y & 0xffff_ffff) }
        v[a] = v[a] &+ v[b] &+ mul(v[a], v[b]); v[d] = (v[d] ^ v[a]).rotated(32)
        v[c] = v[c] &+ v[d] &+ mul(v[c], v[d]); v[b] = (v[b] ^ v[c]).rotated(24)
        v[a] = v[a] &+ v[b] &+ mul(v[a], v[b]); v[d] = (v[d] ^ v[a]).rotated(16)
        v[c] = v[c] &+ v[d] &+ mul(v[c], v[d]); v[b] = (v[b] ^ v[c]).rotated(63)
    }

    /// One lane's working blocks, so that filling a block allocates nothing.
    private final class Scratch {
        let r = block(), q = block(), result = block(), zero = block()
        let input = block(), once = block(), addresses = block()

        private static func block() -> UnsafeMutableBufferPointer<UInt64> {
            let block = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: Argon2id.blockWords)
            block.initialize(repeating: 0)
            return block
        }

        func release() {
            for block in [r, q, result, zero, input, once, addresses] {
                block.update(repeating: 0)
                block.deallocate()
            }
        }
    }

    /// H', Argon2's hash of any length, from BLAKE2b's 64 bytes at a time.
    static func long(_ input: Data, length: Int) -> Data {
        var first = Blake2b(length: min(length, 64))
        first.update(UInt32(length))
        first.update(input)
        guard length > 64 else { return first.finish() }
        var v = first.finish()
        var out = v.prefix(32)
        var remaining = length - 32
        while remaining > 64 {
            v = Blake2b.hash(v)
            out.append(v.prefix(32))
            remaining -= 32
        }
        out.append(Blake2b.hash(v, length: remaining))
        return Data(out)
    }

    private static func le32(_ value: Int) -> [UInt8] {
        withUnsafeBytes(of: UInt32(value).littleEndian) { Array($0) }
    }

    /// The blocks, written by one lane's thread each and read by all of them
    /// across slices, which concurrentPerform keeps apart.
    private final class Memory: @unchecked Sendable {
        let words: UnsafeMutableBufferPointer<UInt64>

        init(blocks: Int) {
            words = .allocate(capacity: blocks * Argon2id.blockWords)
            words.initialize(repeating: 0)
        }

        func block(_ index: Int) -> UnsafeMutableBufferPointer<UInt64> {
            UnsafeMutableBufferPointer(rebasing: words[(index * Argon2id.blockWords)..<((index + 1) * Argon2id.blockWords)])
        }

        func write(_ bytes: Data, at index: Int) {
            bytes.withUnsafeBytes { raw in
                for i in 0..<Argon2id.blockWords {
                    words[index * Argon2id.blockWords + i] = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self))
                }
            }
        }

        func release() {
            words.update(repeating: 0)
            words.deallocate()
        }
    }
}
