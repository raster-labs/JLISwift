// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// Huffman table, encoding, and decoding for JPEG entropy coding.

// MARK: - Huffman Table

/// A compiled Huffman table for encoding or decoding.
struct HuffmanTable {
    /// Number of codes at each bit length (1–16).
    let bits: [UInt8]
    /// The code and bit length for each symbol (for encoding).
    /// Index is the symbol value; value is (code, bitLength).
    let encodingTable: [(code: UInt16, length: UInt8)]

    /// For decoding: maximum code value at each bit length (1–16).
    let maxCode: [Int32]
    /// For decoding: minimum code value at each bit length.
    let minCode: [Int32]
    /// For decoding: index into values array for each bit length.
    let valPtr: [Int]
    /// Ordered symbol values.
    let values: [UInt8]

    /// Lookahead decode tables, indexed by the next 8 bits of the stream.
    /// `lookaheadLength[i]` is the bit length (1–8) of the code whose canonical
    /// prefix matches the top bits of `i`, or 0 when the code is longer than 8
    /// bits (no ≤8-bit code is a prefix of `i`). `lookaheadSymbol[i]` is the
    /// decoded symbol when the length is non-zero. This is the standard
    /// table-driven fast path (libjpeg's `HUFF_LOOKAHEAD = 8`): one buffered
    /// byte resolves the common short codes in O(1), and the prefix-free
    /// property guarantees the result is identical to walking the code
    /// bit-by-bit. Codes >8 bits and any byte near a marker fall back to the
    /// bit-by-bit reader, so error/restart handling is unchanged.
    let lookaheadLength: [UInt8]
    let lookaheadSymbol: [UInt8]

    /// Builds a Huffman table from JPEG-standard bits and values arrays.
    ///
    /// - Parameters:
    ///   - bits: 16-element array, where `bits[i]` is the number of codes of length `i+1`.
    ///   - values: Symbol values in order of increasing code length.
    init(bits: [UInt8], values: [UInt8]) {
        self.bits = bits
        self.values = values
        var encoding = [(code: UInt16, length: UInt8)](repeating: (0, 0), count: 256)

        var maxC = [Int32](repeating: -1, count: 17)
        var minC = [Int32](repeating: -1, count: 17)
        var vPtr = [Int](repeating: 0, count: 17)
        var laLen = [UInt8](repeating: 0, count: 256)
        var laSym = [UInt8](repeating: 0, count: 256)

        compileHuffman(bits: { bits[$0] }, valueCount: values.count, value: { values[$0] },
            encoding: { encoding[$0] = ($1, $2) }, maxCode: { maxC[$0] = $1 },
            minCode: { minC[$0] = $1 }, valPtr: { vPtr[$0] = $1 },
            lookahead: { laLen[$0] = $1; laSym[$0] = $2 })

        self.encodingTable = encoding
        self.maxCode = maxC
        self.minCode = minC
        self.valPtr = vPtr
        self.lookaheadLength = laLen
        self.lookaheadSymbol = laSym
    }
}

// MARK: - Standard JPEG Huffman Tables (ITU-T T.81 Annex K)

/// Standard Huffman table definitions from the JPEG specification.
/// Read-only literal bytes shared by owned and caller-storage table compilation.
/// Hex literals avoid lazy Array allocation in caller-storage fallbacks.
struct HuffmanDefinition {
    let bitsHex: StaticString
    let valuesHex: StaticString
    var count: Int { valuesHex.utf8CodeUnitCount / 2 }
    private func byte(_ hex: StaticString, _ index: Int) -> UInt8 {
        hex.withUTF8Buffer { bytes in
            func digit(_ c: UInt8) -> UInt8 { c <= 57 ? c - 48 : c - 87 }
            return digit(bytes[index * 2]) * 16 + digit(bytes[index * 2 + 1])
        }
    }
    func bit(_ index: Int) -> UInt8 { byte(bitsHex, index) }
    func value(_ index: Int) -> UInt8 { byte(valuesHex, index) }
    func owned() -> HuffmanTable {
        HuffmanTable(bits: (0..<16).map { bit($0) }, values: (0..<count).map { value($0) })
    }
}

enum StandardHuffmanTables {
    static let dcLuminanceDefinition = HuffmanDefinition(
        bitsHex: "00010501010101010100000000000000",
        valuesHex: "000102030405060708090a0b")
    static let dcLuminance = dcLuminanceDefinition.owned()
    static let dcChrominanceDefinition = HuffmanDefinition(
        bitsHex: "00030101010101010101010000000000",
        valuesHex: "000102030405060708090a0b")
    static let dcChrominance = dcChrominanceDefinition.owned()
    static let acLuminanceDefinition = HuffmanDefinition(
        bitsHex: "0002010303020403050504040000017d",
        valuesHex: "01020300041105122131410613516107227114328191a1082342b1c11552d1f02433627282090a161718191a25262728292a3435363738393a434445464748494a535455565758595a636465666768696a737475767778797a838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae1e2e3e4e5e6e7e8e9eaf1f2f3f4f5f6f7f8f9fa")
    static let acLuminance = acLuminanceDefinition.owned()
    static let acChrominanceDefinition = HuffmanDefinition(
        bitsHex: "00020102040403040705040400010277",
        valuesHex: "000102031104052131061241510761711322328108144291a1b1c109233352f0156272d10a162434e125f11718191a262728292a35363738393a434445464748494a535455565758595a636465666768696a737475767778797a82838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae2e3e4e5e6e7e8e9eaf2f3f4f5f6f7f8f9fa")
    static let acChrominance = acChrominanceDefinition.owned()
}

// MARK: - Optimal Huffman Table Generation

/// Builds image-optimal Huffman tables from symbol frequencies, per the
/// procedure in ITU-T T.81 Annex K.2 (the same algorithm libjpeg uses for
/// `-optimize`). Replacing the fixed Annex K tables with per-image tables
/// typically shrinks entropy-coded output 10–50% at identical quality, since
/// the fixed tables are tuned for a generic photo and waste bits on symbol
/// distributions that don't match the actual image.
enum HuffmanTableBuilder {

    /// Generates an optimal Huffman table from `frequencies` (indexed by symbol,
    /// at least 256 entries). Returns `fallback` unchanged when no symbols were
    /// counted — an empty table can't encode anything and some decoders reject
    /// empty DHT segments, so the standard table is a safe no-op there.
    static func build(frequencies: [Int], fallback: HuffmanTable) -> HuffmanTable {
        if frequencies.reduce(0, +) == 0 { return fallback }

        // freq[256] is a reserved code point that guarantees no real symbol gets
        // the all-ones code (forbidden by JPEG). Work on a 257-entry copy.
        var freq = [Int](repeating: 0, count: 257)
        for i in 0..<min(256, frequencies.count) { freq[i] = frequencies[i] }
        freq[256] = 1

        var codesize = [Int](repeating: 0, count: 257)
        var others = [Int](repeating: -1, count: 257)

        // Repeatedly merge the two least-frequent live nodes (Huffman tree build),
        // tracking each merged chain's growing code length in `codesize`.
        while true {
            var c1 = -1, v = Int.max
            for i in 0...256 where freq[i] > 0 && freq[i] <= v { v = freq[i]; c1 = i }
            var c2 = -1; v = Int.max
            for i in 0...256 where freq[i] > 0 && freq[i] <= v && i != c1 { v = freq[i]; c2 = i }
            if c2 < 0 { break }

            freq[c1] += freq[c2]
            freq[c2] = 0
            codesize[c1] += 1
            while others[c1] >= 0 { c1 = others[c1]; codesize[c1] += 1 }
            others[c1] = c2
            codesize[c2] += 1
            while others[c2] >= 0 { c2 = others[c2]; codesize[c2] += 1 }
        }

        // Count codes of each length (1–32 before limiting).
        var bits = [Int](repeating: 0, count: 33)
        for i in 0...256 where codesize[i] > 0 { bits[codesize[i]] += 1 }

        // Limit code lengths to 16 bits (Annex K.2, figure K.3). Each over-long
        // code is shortened by reshaping the prefix tree, keeping it a valid
        // prefix code.
        var i = 32
        while i > 16 {
            while bits[i] > 0 {
                var j = i - 2
                while bits[j] == 0 { j -= 1 }
                bits[i] -= 2
                bits[i - 1] += 1
                bits[j + 1] += 2
                bits[j] -= 1
            }
            i -= 1
        }
        // Drop the reserved code point: decrement the longest non-empty length.
        i = 16
        while i > 0 && bits[i] == 0 { i -= 1 }
        if i > 0 { bits[i] -= 1 }

        var bits16 = [UInt8](repeating: 0, count: 16)
        for len in 1...16 { bits16[len - 1] = UInt8(bits[len]) }

        // HUFFVAL: real symbols (0–255) ordered by increasing original code length.
        // Symbol 256 (reserved) is naturally excluded by the 0...255 range.
        var values = [UInt8]()
        for len in 1...32 {
            for sym in 0...255 where codesize[sym] == len { values.append(UInt8(sym)) }
        }

        return HuffmanTable(bits: bits16, values: values)
    }
}

// MARK: - Huffman Encoding

/// Huffman entropy encoder for JPEG data.
enum HuffmanEncoder {

    /// Returns the category (number of bits) needed to represent a value.
    ///
    /// Category 0 = value 0, category 1 = -1..1, category 2 = -3..-2, 2..3, etc.
    /// One CLZ instruction: `bits(|v|) = 32 − clz(|v|)` (and `clz(0) = 32` makes
    /// the zero case fall out naturally). Identical to counting shifts — this
    /// runs twice per sample in lossless encode, so it must be branch-free.
    @inline(__always)
    static func category(for value: Int32) -> Int {
        Int(32 - value.magnitude.leadingZeroBitCount)
    }

    /// Returns the additional bits to encode after the Huffman category code.
    ///
    /// For positive values: the value itself. For negative: `value + (1 << category) - 1`.
    static func additionalBits(for value: Int32, category cat: Int) -> UInt32 {
        if cat == 0 { return 0 }
        if value >= 0 {
            return UInt32(value)
        } else {
            return UInt32(Int(value) + (1 << cat) - 1)
        }
    }

    /// Counts the Huffman symbol a DC difference would emit, without writing bits.
    /// Mirrors ``encodeDC(_:table:writer:)`` exactly so a counting pass and an
    /// emit pass agree on which symbols appear. `freq` is indexed by symbol (0–255).
    static func countDC(_ diff: Int32, freq: inout [Int]) {
        freq[category(for: diff)] += 1
    }

    /// Counts the Huffman symbols the 63 AC coefficients would emit. Mirrors
    /// ``encodeAC(_:table:writer:)``.
    static func countAC(_ zigzag: [Int32], freq: inout [Int]) {
        var zeroRun = 0
        for i in 1..<64 {
            let value = zigzag[i]
            if value == 0 {
                zeroRun += 1
            } else {
                while zeroRun > 15 {
                    freq[0xF0] += 1  // ZRL
                    zeroRun -= 16
                }
                freq[(zeroRun << 4) | category(for: value)] += 1
                zeroRun = 0
            }
        }
        if zeroRun > 0 { freq[0x00] += 1 }  // EOB
    }

    /// Encodes a DC coefficient difference using the given Huffman table.
    ///
    /// The Huffman code and its appended magnitude bits are emitted in a single
    /// `writeBits` call: appending `n` bits then `m` bits MSB-first produces the
    /// same bit sequence as appending the `n+m`-bit concatenation, and stuffing/
    /// padding are pure functions of the bit sequence — so the stream is
    /// byte-identical while halving the mutating-writer calls. Max combined
    /// width is 16 (code) + 15 (DCT magnitude) = 31 bits, within `writeBits`'
    /// 32-bit value.
    static func encodeDC(_ diff: Int32, table: HuffmanTable, writer: inout BitWriter) {
        let cat = category(for: diff)
        let entry = table.encodingTable[cat]
        if cat > 0 {
            let fused = (UInt32(entry.code) << cat) | additionalBits(for: diff, category: cat)
            writer.writeBits(fused, count: Int(entry.length) + cat)
        } else {
            writer.writeBits(UInt32(entry.code), count: Int(entry.length))
        }
    }

    /// Encodes the 63 AC coefficients of a block (in zigzag order, starting from index 1).
    static func encodeAC(_ zigzag: [Int32], table: HuffmanTable, writer: inout BitWriter) {
        var zeroRun = 0

        for i in 1..<64 {
            let value = zigzag[i]
            if value == 0 {
                zeroRun += 1
            } else {
                // Emit ZRL (zero run length) symbols for runs > 15
                while zeroRun > 15 {
                    let entry = table.encodingTable[0xF0]  // ZRL symbol
                    writer.writeBits(UInt32(entry.code), count: Int(entry.length))
                    zeroRun -= 16
                }
                let cat = category(for: value)
                let symbol = (zeroRun << 4) | cat
                let entry = table.encodingTable[symbol]
                // Code + magnitude bits in one call (see encodeDC) — identical
                // bitstream, half the writer calls. AC cat ≤ 14 → ≤ 30 bits.
                let fused = (UInt32(entry.code) << cat) | additionalBits(for: value, category: cat)
                writer.writeBits(fused, count: Int(entry.length) + cat)
                zeroRun = 0
            }
        }

        // EOB (End of Block) if the last coefficient(s) were zero
        if zeroRun > 0 {
            let entry = table.encodingTable[0x00]  // EOB symbol
            writer.writeBits(UInt32(entry.code), count: Int(entry.length))
        }
    }
}

// MARK: - Huffman Decoding

/// Huffman entropy decoder for JPEG data.
enum HuffmanDecoder {

    /// Decodes a single Huffman symbol from the bit stream.
    static func decodeSymbol<Table: HuffmanDecodeTable>(from reader: inout BitReader, table: Table) throws -> UInt8 {
        // Fast path: resolve short (≤8-bit) codes from an 8-bit lookahead table.
        // Falls through to the bit-by-bit walk for long codes and any byte near
        // a marker / end of data, so all error and restart handling is unchanged.
        if let symbol = reader.fastDecodeSymbol(table) { return symbol }
        return try decodeSymbolBitByBit(from: &reader, table: table)
    }

    /// Bit-by-bit Huffman symbol decode: reads one bit at a time, comparing the
    /// accumulated code against `maxCode` at each length (ITU-T T.81 F.2.2.3).
    /// This is the reference/fallback path — it owns all long-code (>8-bit),
    /// marker, EOF, and malformed-table handling. ``decodeSymbol(from:table:)``
    /// only short-circuits to the lookahead table when it can prove the result
    /// is identical to this walk.
    static func decodeSymbolBitByBit<Table: HuffmanDecodeTable>(
        from reader: inout BitReader, table: Table
    ) throws -> UInt8 {
        var code: Int32 = 0

        for bitLength in 1...16 {
            let bit = try reader.readBit()
            code = (code << 1) | Int32(bit)

            if table.maxCode[bitLength] >= 0 && code <= table.maxCode[bitLength] {
                let index = table.valPtr[bitLength] + Int(code - table.minCode[bitLength])
                // A malformed DHT (e.g. a corrupted code-count byte) can yield a
                // valPtr/minCode that points past the value list; bounds-check
                // rather than trap on untrusted input.
                guard index >= 0, index < table.values.count else {
                    throw JLIError.decodingFailed("Huffman code index out of range")
                }
                return table.values[index]
            }
        }

        throw JLIError.decodingFailed("Invalid Huffman code")
    }

    /// Decodes a signed value from additional bits after a Huffman category.
    static func decodeValue(from reader: inout BitReader, category cat: Int) throws -> Int32 {
        guard cat > 0 else { return 0 }
        guard cat <= 16 else { throw JLIError.decodingFailed("Invalid Huffman value category") }

        let bits = try reader.readBits(cat)
        // If MSB is 0, the value is negative
        if bits < (1 << (cat - 1)) {
            return Int32(bits) - Int32((1 << cat) - 1)
        } else {
            return Int32(bits)
        }
    }

    /// Decodes a DC coefficient from the bit stream.
    static func decodeDC<Table: HuffmanDecodeTable>(from reader: inout BitReader, table: Table) throws -> Int32 {
        let cat = Int(try decodeSymbol(from: &reader, table: table))
        return try decodeValue(from: &reader, category: cat)
    }

    /// Decodes the 63 AC coefficients of a block from the bit stream.
    ///
    /// Returns 64 coefficients in zigzag order (index 0 is left empty for DC).
    static func decodeAC(from reader: inout BitReader, table: HuffmanTable) throws -> [Int32] {
        var coefficients = [Int32](repeating: 0, count: 64)
        try decodeAC(from: &reader, table: table, into: &coefficients)
        return coefficients
    }

    /// In-place variant: decodes 64 zigzag-order AC coefficients into `out`.
    /// Caller's buffer is zeroed before decoding. Saves an `[Int32](repeating:)`
    /// allocation per block in the decoder hot loop.
    static func decodeAC(
        from reader: inout BitReader, table: HuffmanTable, into out: inout [Int32]
    ) throws {
        try out.withUnsafeMutableBufferPointer { buffer in
            try decodeAC(from: &reader, table: table, into: buffer)
        }
    }

    static func decodeAC<Table: HuffmanDecodeTable>(from reader: inout BitReader, table: Table,
        into out: UnsafeMutableBufferPointer<Int32>) throws {
        precondition(out.count == 64)
        for i in 0..<64 { out[i] = 0 }

        var index = 1
        while index < 64 {
            let symbol = try decodeSymbol(from: &reader, table: table)

            if symbol == 0x00 {
                break  // EOB — remaining coefficients are zero
            }
            if symbol == 0xF0 {
                index += 16  // ZRL — skip 16 zeros
                continue
            }

            let zeroRun = Int(symbol >> 4)
            let cat = Int(symbol & 0x0F)
            index += zeroRun
            guard index < 64 else { break }

            out[index] = try decodeValue(from: &reader, category: cat)
            index += 1
        }
    }
}

// Shared canonical table compiler. Storage is supplied by the legacy table or
// caller-workspace view; encoding storage is optional for decode-only consumers.
private func compileHuffman(
    bits: (Int) -> UInt8, valueCount: Int, value: (Int) -> UInt8,
    encoding: (Int, UInt16, UInt8) -> Void,
    maxCode: (Int, Int32) -> Void, minCode: (Int, Int32) -> Void,
    valPtr: (Int, Int) -> Void, lookahead: (Int, UInt8, UInt8) -> Void
) {
        // Wider than the 16-bit codes it produces so canonical-code generation
        // can't overflow on a malformed BITS array — a complete length-16 code
        // walks `code` up to 2^16, one past UInt16's range. Stored codes still
        // fit in 16 bits for any well-formed table.
        var code: UInt32 = 0
        var valueIndex = 0

        for bitLength in 1...16 {
            let count = Int(bits(bitLength - 1))
            if count > 0 {
                valPtr(bitLength, valueIndex)
                minCode(bitLength, Int32(code))
                for _ in 0..<count where valueIndex < valueCount {
                    let symbol = value(valueIndex)
                    encoding(Int(symbol), UInt16(truncatingIfNeeded: code), UInt8(bitLength))
                    // Fill every 8-bit lookahead slot whose top `bitLength` bits
                    // equal this code. A canonical code of length ≤8 is < 256,
                    // so `code << (8 - bitLength)` and its run stay in 0...255.
                    if bitLength <= 8 {
                        let shift = 8 - bitLength
                        let start = Int(code << shift)
                        for k in start..<(start + (1 << shift)) {
                            lookahead(k, UInt8(bitLength), symbol)
                        }
                    }
                    valueIndex += 1
                    code += 1
                }
                maxCode(bitLength, Int32(code - 1))
            }
            code <<= 1
        }

 }

protocol HuffmanDecodeTable {
    associatedtype Codes: RandomAccessCollection where Codes.Index == Int, Codes.Element == Int32
    associatedtype Offsets: RandomAccessCollection where Offsets.Index == Int, Offsets.Element == Int
    associatedtype Bytes: RandomAccessCollection where Bytes.Index == Int, Bytes.Element == UInt8
    var maxCode: Codes { get }
    var minCode: Codes { get }
    var valPtr: Offsets { get }
    var values: Bytes { get }
    var lookaheadLength: Bytes { get }
    var lookaheadSymbol: Bytes { get }
}
extension HuffmanTable: HuffmanDecodeTable {}

/// A decode-only table in caller workspace. No Array storage or encoder table.
struct BorrowedHuffmanTable: HuffmanDecodeTable {
    let maxCode: UnsafeMutableBufferPointer<Int32>
    let minCode: UnsafeMutableBufferPointer<Int32>
    let valPtr: UnsafeMutableBufferPointer<Int>
    let values: UnsafeMutableBufferPointer<UInt8>
    let lookaheadLength: UnsafeMutableBufferPointer<UInt8>
    let lookaheadSymbol: UnsafeMutableBufferPointer<UInt8>
    static let byteCount = 1040

    init(workspace: UnsafeMutableRawBufferPointer, valueCount: Int,
         bits: (Int) -> UInt8, value: (Int) -> UInt8) {
        precondition(workspace.count >= Self.byteCount && valueCount <= 256)
        func buffer<T>(_ type: T.Type, _ offset: Int, _ count: Int) -> UnsafeMutableBufferPointer<T> {
            UnsafeMutableRawBufferPointer(rebasing: workspace[offset..<(offset + count * MemoryLayout<T>.stride)])
                .bindMemory(to: T.self)
        }
        maxCode = buffer(Int32.self, 0, 17); minCode = buffer(Int32.self, 68, 17)
        valPtr = buffer(Int.self, 136, 17); values = buffer(UInt8.self, 272, valueCount)
        lookaheadLength = buffer(UInt8.self, 528, 256); lookaheadSymbol = buffer(UInt8.self, 784, 256)
        maxCode.initialize(repeating: -1); minCode.initialize(repeating: -1); valPtr.initialize(repeating: 0)
        lookaheadLength.initialize(repeating: 0); lookaheadSymbol.initialize(repeating: 0)
        for index in 0..<valueCount { values[index] = value(index) }
        compileHuffman(bits: bits, valueCount: valueCount, value: value, encoding: { _, _, _ in },
            maxCode: { maxCode[$0] = $1 }, minCode: { minCode[$0] = $1 }, valPtr: { valPtr[$0] = $1 },
            lookahead: { lookaheadLength[$0] = $1; lookaheadSymbol[$0] = $2 })
    }
}
