// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// JPEG marker reader and parser for the decoder pipeline.
///
/// Parses JPEG marker segments to extract frame information, quantization tables,
/// Huffman tables, and entropy-coded scan data.

// MARK: - Parsed JPEG Data Structures

/// Information about a single JPEG component from the SOF marker.
struct JPEGComponentInfo: Sendable {
    let id: UInt8
    let horizontalSampling: Int
    let verticalSampling: Int
    let quantTableIndex: Int
}

/// Frame header information from the SOF marker.
struct JPEGFrameInfo: Sendable {
    let precision: Int
    let width: Int
    let height: Int
    let components: [JPEGComponentInfo]
    let isProgressive: Bool
    /// SOF3 — lossless (predictive, no DCT). The SOS `spectralStart` carries the
    /// predictor selection (1–7) and `successiveApproxLow` the point transform.
    var isLossless: Bool = false
}

/// Scan header information from the SOS marker.
struct JPEGScanHeader: Sendable {
    let components: [(componentSelector: UInt8, dcTableId: Int, acTableId: Int)]
    let spectralStart: Int
    let spectralEnd: Int
    let successiveApproxHigh: Int
    let successiveApproxLow: Int
}

/// A single scan's data extracted from the JPEG stream.
struct JPEGScanData: Sendable {
    let header: JPEGScanHeader
    let entropyData: [UInt8]
    /// Huffman tables in effect when this scan's SOS was parsed. Progressive
    /// JPEGs redefine DHT tables between scans, so each scan must use the
    /// snapshot active at its point in the stream, not a global merge.
    let dcTables: [Int: HuffmanTable]
    let acTables: [Int: HuffmanTable]
}

/// Fully parsed JPEG data ready for decoding.
struct ParsedJPEG: Sendable {
    let frameInfo: JPEGFrameInfo
    let quantTables: [[Int]]
    let huffmanDCTables: [Int: HuffmanTable]
    let huffmanACTables: [Int: HuffmanTable]
    let scans: [JPEGScanData]
    /// Number of MCUs between restart markers. 0 means no restart markers in the
    /// stream. Apple ImageIO and many other encoders emit DRI + RST0–RST7 for
    /// error resilience even on baseline JPEGs.
    let restartInterval: Int
    /// ICC color profile reassembled from APP2 `ICC_PROFILE` segments, or nil.
    let iccProfile: [UInt8]?
    /// Exif payload (APP1 body after the `Exif\0\0` identifier), or nil.
    let exif: [UInt8]?
    /// Adobe APP14 transform: zero denotes untransformed RGB for three components.
    var adobeTransform: UInt8? = nil
}

// MARK: - Marker Reader

/// Reads and parses JPEG marker segments from a byte buffer.
struct MarkerReader {
    private let data: JPEGByteView
    private let callerStorage: (any JPEGParseCapture)?
    private var offset: Int = 0
    private var nextCancellationCheckpoint = 65_536

    init(data: [UInt8]) {
        self.data = JPEGByteView(data)
        self.callerStorage = nil
    }

    init(borrowing data: UnsafeRawBufferPointer, storage: any JPEGParseCapture) {
        self.data = JPEGByteView(borrowing: data); callerStorage = storage
    }

    /// Reads JPEG info without full decode.
    mutating func readInfo() throws -> JLIJPEGInfo {
        try validateSOI()

        var frameInfo: JPEGFrameInfo?

        while offset < data.count - 1 {
            guard let marker = try nextMarker() else { break }

            switch marker {
            case JPEGMarker.sof0, JPEGMarker.sof1, JPEGMarker.sof2, JPEGMarker.sof3:
                // SOF0 baseline + SOF1 extended sequential decode identically
                // (both Huffman sequential); SOF1 just permits 12-bit precision.
                frameInfo = try readSOF(progressive: marker == JPEGMarker.sof2,
                                        lossless: marker == JPEGMarker.sof3)

            case JPEGMarker.eoi:
                break

            case JPEGMarker.sos:
                // Skip scan data for info-only parsing
                break

            default:
                try skipSegment()
            }

            if frameInfo != nil {
                break  // We have what we need
            }
        }

        guard let frame = frameInfo else {
            throw JLIError.invalidJPEGData
        }

        let subsampling = detectChromaSubsampling(frame.components)

        return JLIJPEGInfo(
            width: frame.width,
            height: frame.height,
            componentCount: frame.components.count,
            bitsPerComponent: frame.precision,
            isProgressive: frame.isProgressive,
            isXYB: false,
            isExtendedPrecision: frame.precision > 8,
            chromaSubsampling: subsampling
        )
    }

    /// Fully parses the JPEG stream, extracting all tables and scan data.
    mutating func parse() throws -> ParsedJPEG {
        try validateSOI()

        var sawEOI = false
        var adobeTransform: UInt8?
        var frameInfo: JPEGFrameInfo?
        var quantTables = callerStorage == nil ? [[Int]](repeating: [Int](repeating: 0, count: 64), count: 4) : []
        var huffDC = [Int: HuffmanTable]()
        var huffAC = [Int: HuffmanTable]()
        var scans: [JPEGScanData] = []
        var restartInterval: Int = 0
        var exifData: [UInt8]? = nil
        var iccChunks: [Int: [UInt8]] = [:]   // sequence number → chunk payload

        markers: while offset < data.count - 1 {
            if callerStorage != nil { try Task.checkCancellation() }
            guard let marker = try nextMarker() else { break }

            switch marker {
            case JPEGMarker.sof0, JPEGMarker.sof1, JPEGMarker.sof2, JPEGMarker.sof3:
                // SOF0 baseline + SOF1 extended sequential decode identically
                // (both Huffman sequential); SOF1 just permits 12-bit precision.
                guard frameInfo == nil else { throw JLIError.decodingFailed("Multiple SOF markers") }
                frameInfo = try readSOF(progressive: marker == JPEGMarker.sof2,
                                        lossless: marker == JPEGMarker.sof3)

            case JPEGMarker.dqt:
                let tables = try readDQT()
                for (id, values) in tables {
                    quantTables[id] = values
                }

            case JPEGMarker.dht:
                let tables = try readDHT()
                for (tableClass, tableId, table) in tables {
                    if tableClass == 0 {
                        huffDC[tableId] = table
                    } else {
                        huffAC[tableId] = table
                    }
                }

            case JPEGMarker.dri:
                // Length=4, then 2-byte restart interval.
                guard try readUInt16() == 4 else { throw JLIError.decodingFailed("Invalid DRI length") }
                restartInterval = Int(try readUInt16())

            case JPEGMarker.sos:
                let scanHeader = try readSOS()
                if let callerStorage, scans.count >= callerStorage.maximumScans {
                    throw JLIError.unsupportedJPEGFeature("Too many caller-storage scans")
                }
                let entropyRange = try readEntropyRange()
                if let callerStorage {
                    try callerStorage.scan(scanHeader, frame: frameInfo, entropy: entropyRange, restartInterval: restartInterval)
                }
                let entropyData = callerStorage == nil ? Array(data[entropyRange]) : []
                // Snapshot the tables active right now (progressive redefines them).
                scans.append(JPEGScanData(
                    header: scanHeader, entropyData: entropyData,
                    dcTables: huffDC, acTables: huffAC
                ))

            case JPEGMarker.eoi:
                sawEOI = true
                guard offset == data.count || (offset % 2 == 1 && offset + 1 == data.count && data[offset] == 0) else {
                    throw JLIError.decodingFailed("Trailing bytes or concatenated JPEG codestream")
                }
                break markers

            case 0xee:
                if let callerStorage {
                    let range = try readSegmentRange()
                    callerStorage.application(marker: marker, range: range, input: data)
                    continue
                }
                let segment = try readSegmentBytes()
                if segment.count >= 12 && Array(segment.prefix(5)) == [65, 100, 111, 98, 101] {
                    adobeTransform = segment[11]
                }

            case JPEGMarker.app1:
                if let callerStorage {
                    let range = try readSegmentRange()
                    callerStorage.application(marker: marker, range: range, input: data)
                    continue
                }
                // Exif: "Exif\0\0" identifier then the TIFF payload we preserve.
                let seg = try readSegmentBytes()
                let exifID: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]
                if exifData == nil, seg.count >= 6, Array(seg[0..<6]) == exifID {
                    exifData = Array(seg[6...])
                }

            case JPEGMarker.app2:
                if let callerStorage {
                    let range = try readSegmentRange()
                    callerStorage.application(marker: marker, range: range, input: data)
                    continue
                }
                // ICC: "ICC_PROFILE\0" (12) + seq (1-based) + count, then a chunk
                // of the profile. Accumulate by sequence number; reassemble below.
                let seg = try readSegmentBytes()
                let iccID: [UInt8] = [0x49, 0x43, 0x43, 0x5F, 0x50, 0x52,
                                      0x4F, 0x46, 0x49, 0x4C, 0x45, 0x00]
                if seg.count >= 14, Array(seg[0..<12]) == iccID {
                    let seq = Int(seg[12])
                    if iccChunks[seq] == nil { iccChunks[seq] = Array(seg[14...]) }
                }

            case 0xD0...0xD7:
                // RST0–RST7 — restart markers have no length field and should
                // normally be consumed by `readEntropyData`. A bare one at the
                // top level (after a scan that already exited cleanly) is
                // harmless; just skip it.
                continue

            default:
                try skipSegment()
            }
        }

        guard sawEOI else { throw JLIError.decodingFailed("Missing JPEG EOI marker") }

        // Reassemble the ICC profile from its chunks in sequence order. Only
        // accept a contiguous 1..n run so a malformed/partial set yields nil
        // rather than a silently-corrupt profile.
        var iccProfile: [UInt8]? = nil
        if !iccChunks.isEmpty {
            let seqs = iccChunks.keys.sorted()
            if seqs == Array(1...seqs.count) {
                iccProfile = seqs.reduce(into: [UInt8]()) { $0 += iccChunks[$1]! }
            }
        }

        guard let frame = frameInfo else {
            throw JLIError.invalidJPEGData
        }

        return ParsedJPEG(
            frameInfo: frame,
            quantTables: quantTables,
            huffmanDCTables: huffDC,
            huffmanACTables: huffAC,
            scans: scans,
            restartInterval: restartInterval,
            iccProfile: iccProfile,
            exif: exifData, adobeTransform: adobeTransform
        )
    }

    // MARK: - Private Parsing Methods

    private mutating func segmentEnd(minimumPayload: Int) throws -> Int {
        let payload = Int(try readUInt16()) - 2
        guard payload >= minimumPayload, payload <= data.count - offset else {
            throw JLIError.decodingFailed("Invalid or truncated JPEG segment length")
        }
        return offset + payload
    }

    private mutating func validateSOI() throws {
        guard data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 else {
            throw JLIError.invalidJPEGData
        }
        offset = 2
    }

    /// Reads the next marker byte, skipping padding 0xFF bytes.
    private mutating func nextMarker() throws -> UInt8? {
        while offset < data.count {
            try checkCancellation()
            if data[offset] == 0xFF {
                offset += 1
                // Skip padding 0xFF bytes
                while offset < data.count && data[offset] == 0xFF {
                    try checkCancellation()
                    offset += 1
                }
                if offset < data.count && data[offset] != 0x00 {
                    let marker = data[offset]
                    offset += 1
                    return marker
                }
            } else {
                offset += 1
            }
        }
        return nil
    }

    /// Reads the segment length and skips past the segment data.
    private mutating func skipSegment() throws {
        let length = try readUInt16()
        let skip = Int(length) - 2
        guard skip >= 0, offset + skip <= data.count else {
            throw JLIError.decodingFailed("Invalid segment length")
        }
        offset += skip
    }

    /// Reads the segment length and returns the segment's payload bytes (the
    /// `length − 2` bytes after the length field), advancing past them. Used to
    /// capture APP1/APP2 metadata segments.
    private mutating func readSegmentBytes() throws -> [UInt8] {
        let length = try readUInt16()
        let n = Int(length) - 2
        guard n >= 0, offset + n <= data.count else {
            throw JLIError.decodingFailed("Invalid segment length")
        }
        let bytes = Array(data[offset..<offset + n])
        offset += n
        return bytes
    }

    private mutating func readSegmentRange() throws -> Range<Int> {
        let end = try segmentEnd(minimumPayload: 0)
        let start = offset
        offset = end
        return start..<end
    }

    /// Reads a SOF (Start of Frame) marker.
    private mutating func readSOF(progressive: Bool, lossless: Bool = false) throws -> JPEGFrameInfo {
        let endOffset = try segmentEnd(minimumPayload: 6)

        let precision = Int(try readByte())
        let height = Int(try readUInt16())
        let width = Int(try readUInt16())
        let numComponents = Int(try readByte())
        if let callerStorage, !callerStorage.accepts(componentCount: numComponents) {
            throw JLIError.unsupportedJPEGFeature("Unsupported caller-storage component count")
        }

        guard endOffset - offset == numComponents * 3 else { throw JLIError.decodingFailed("Invalid SOF length") }
        var components = [JPEGComponentInfo]()
        for _ in 0..<numComponents {
            let id = try readByte()
            let sampling = try readByte()
            let quantId = try readByte()
            components.append(JPEGComponentInfo(
                id: id,
                horizontalSampling: Int(sampling >> 4),
                verticalSampling: Int(sampling & 0x0F),
                quantTableIndex: Int(quantId)
            ))
        }

        offset = endOffset
        return JPEGFrameInfo(
            precision: precision,
            width: width,
            height: height,
            components: components,
            isProgressive: progressive,
            isLossless: lossless
        )
    }

    /// Reads a DQT (Define Quantization Table) marker.
    private mutating func readDQT() throws -> [(id: Int, values: [Int])] {
        let endOffset = try segmentEnd(minimumPayload: 0)
        var tables = [(id: Int, values: [Int])]()

        while offset < endOffset {
            let info = try readByte()
            let precision = Int(info >> 4)
            let tableId = Int(info & 0x0F)
            // T.81: Pq (precision) is 0 (8-bit) or 1 (16-bit); Tq (table id) is
            // 0–3. A corrupted DQT length desyncs parsing and feeds garbage here,
            // so reject out-of-range ids/precision rather than indexing past the
            // 4-slot quant-table array.
            guard precision == 0 || precision == 1 else {
                throw JLIError.decodingFailed("invalid DQT precision \(precision)")
            }
            guard tableId <= 3 else {
                throw JLIError.decodingFailed("invalid DQT table id \(tableId)")
            }

            guard endOffset - offset >= 64 * (precision + 1) else { throw JLIError.decodingFailed("Truncated DQT segment") }
            if let callerStorage {
                let start = offset
                for _ in 0..<64 {
                    if precision == 0 { _ = try readByte() } else { _ = try readUInt16() }
                }
                callerStorage.quantization(id: tableId, precision: precision, range: start..<offset)
                continue
            }
            var values = [Int](repeating: 0, count: 64)
            for i in 0..<64 {
                if precision == 0 {
                    values[i] = Int(try readByte())
                } else {
                    values[i] = Int(try readUInt16())
                }
            }
            tables.append((id: tableId, values: values))
        }

        return tables
    }

    /// Reads a DHT (Define Huffman Table) marker.
    private mutating func readDHT() throws -> [(tableClass: Int, tableId: Int, table: HuffmanTable)] {
        let endOffset = try segmentEnd(minimumPayload: 0)
        var tables = [(tableClass: Int, tableId: Int, table: HuffmanTable)]()

        while offset < endOffset {
            let info = try readByte()
            let tableClass = Int(info >> 4)
            let tableId = Int(info & 0x0F)

            guard endOffset - offset >= 16 else { throw JLIError.decodingFailed("Truncated DHT counts") }
            let bitsStart = offset
            var totalValues = 0
            var codeSpace = 0
            for len in 1...16 {
                let count = Int(try readByte())
                totalValues += count
                codeSpace += count
                guard codeSpace <= (1 << len) else {
                    throw JLIError.decodingFailed("invalid DHT: Huffman code oversubscribed at length \(len)")
                }
                codeSpace <<= 1
            }
            guard totalValues <= 256 else {
                throw JLIError.decodingFailed("invalid DHT: \(totalValues) codes (max 256)")
            }
            guard endOffset - offset >= totalValues else { throw JLIError.decodingFailed("Truncated DHT values") }
            let valuesStart = offset
            for _ in 0..<totalValues { _ = try readByte() }
            if let callerStorage {
                callerStorage.table(isDC: tableClass == 0, id: tableId, bits: bitsStart, values: valuesStart, count: totalValues)
                continue
            }
            let bits = Array(data[bitsStart..<(bitsStart + 16)])
            let values = Array(data[valuesStart..<(valuesStart + totalValues)])
            let table = HuffmanTable(bits: bits, values: values)
            tables.append((tableClass: tableClass, tableId: tableId, table: table))
        }

        return tables
    }

    /// Reads a SOS (Start of Scan) marker header.
    private mutating func readSOS() throws -> JPEGScanHeader {
        let endOffset = try segmentEnd(minimumPayload: 4)

        let numComponents = Int(try readByte())
        if let callerStorage, !callerStorage.accepts(componentCount: numComponents) {
            throw JLIError.unsupportedJPEGFeature("Unsupported caller-storage component count")
        }
        guard endOffset - offset == numComponents * 2 + 3 else { throw JLIError.decodingFailed("Invalid SOS length") }
        var components = [(componentSelector: UInt8, dcTableId: Int, acTableId: Int)]()

        for _ in 0..<numComponents {
            let selector = try readByte()
            let tableIds = try readByte()
            components.append((
                componentSelector: selector,
                dcTableId: Int(tableIds >> 4),
                acTableId: Int(tableIds & 0x0F)
            ))
        }

        let spectralStart = Int(try readByte())
        let spectralEnd = Int(try readByte())
        let successive = try readByte()

        return JPEGScanHeader(
            components: components,
            spectralStart: spectralStart,
            spectralEnd: spectralEnd,
            successiveApproxHigh: Int(successive >> 4),
            successiveApproxLow: Int(successive & 0x0F)
        )
    }

    /// Slices the entropy-coded segment between SOS and the next non-RST marker.
    ///
    /// The returned buffer is byte-for-byte identical to what the encoder wrote, including
    /// stuffed `0xFF 0x00` pairs **and** restart markers (`0xFF 0xD0`–`0xFF 0xD7`).
    /// `BitReader` is the single point that performs unstuffing, and the decoder consumes
    /// restart markers explicitly at known MCU boundaries via `skipRestartMarker`.
    private mutating func readEntropyRange() throws -> Range<Int> {
        // The segment is a verbatim slice (stuffed pairs and RST markers stay
        // in; `BitReader` unstuffs), so only the END needs finding: scan to the
        // first 0xFF whose successor is neither 0x00 (stuffing) nor 0xD0–0xD7
        // (RST0–7) — or a trailing lone 0xFF — leaving `offset` on the 0xFF for
        // nextMarker(). One slice copy replaces the previous per-byte append
        // (which paid an Array uniqueness check + growth per byte and showed up
        // at ~7-9% of a whole lossless decode).
        let n = data.count
        let start = offset
        var pos = offset
        var nextCheckpoint = pos
        try data.withUnsafeBytes { p in
            while pos < n {
                if callerStorage != nil, pos >= nextCheckpoint {
                    try Task.checkCancellation()
                    nextCheckpoint = pos > Int.max - 65_536 ? Int.max : pos + 65_536
                }
                if p[pos] != 0xFF { pos += 1; continue }
                guard pos + 1 < n else { break }              // trailing lone 0xFF
                let next = p[pos + 1]
                if next == 0x00 || (next >= 0xD0 && next <= 0xD7) {
                    pos += 2                                   // stuffing / restart
                } else {
                    break                                      // real marker — stop
                }
            }
        }
        offset = pos
        return start..<pos
    }

    // MARK: - Byte Reading Primitives

    private mutating func checkCancellation() throws {
        if callerStorage != nil, offset >= nextCancellationCheckpoint {
            try Task.checkCancellation()
            nextCancellationCheckpoint = offset > Int.max - 65_536 ? Int.max : offset + 65_536
        }
    }

    private mutating func readByte() throws -> UInt8 {
        try checkCancellation()
        guard offset < data.count else {
            throw JLIError.decodingFailed("Unexpected end of JPEG data")
        }
        let byte = data[offset]
        offset += 1
        return byte
    }

    private mutating func readUInt16() throws -> UInt16 {
        let high = try readByte()
        let low = try readByte()
        return (UInt16(high) << 8) | UInt16(low)
    }

    // MARK: - Helpers

    private func detectChromaSubsampling(_ components: [JPEGComponentInfo]) -> JLIChromaSubsampling {
        guard components.count >= 3 else {
            return components.count == 1 ? .yuv400 : .yuv444
        }

        let lumH = components[0].horizontalSampling
        let lumV = components[0].verticalSampling
        let chromH = components[1].horizontalSampling
        let chromV = components[1].verticalSampling

        if lumH == chromH && lumV == chromV {
            return .yuv444
        } else if lumH == 2 && lumV == 1 && chromH == 1 && chromV == 1 {
            return .yuv422
        } else if lumH == 2 && lumV == 2 && chromH == 1 && chromV == 1 {
            return .yuv420
        } else {
            return .yuv444
        }
    }
}
