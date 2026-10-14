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
    let components: JPEGStorageArray<JPEGComponentInfo>
    let isProgressive: Bool
    /// SOF3 — lossless (predictive, no DCT). The SOS `spectralStart` carries the
    /// predictor selection (1–7) and `successiveApproxLow` the point transform.
    var isLossless: Bool = false
}

/// Scan header information from the SOS marker.
struct JPEGScanHeader: Sendable {
    let components: JPEGStorageArray<JPEGScanComponent>
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
    let scans: JPEGStorageArray<JPEGScanData>
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

// These concrete carriers have static ownership layouts. Wrapping parser values
// that retain legacy Array alternatives in generic Result/Optional metadata can
// trigger a cold runtime allocation even when the selected backings are empty.
// This changes only value transport; both storage strategies use the grammar below.
enum JPEGFrameSlot {
    case none
    case some(JPEGFrameInfo)
}

enum JPEGParseOutcome {
    case success(ParsedJPEG)
    case failure(JLICoreFailure)
    var failureValue: JLICoreFailure {
        switch self {
        case .failure(let failure): return failure
        case .success: preconditionFailure("Expected an already-checked failure")
        }
    }
}

enum JPEGFrameOutcome {
    case success(JPEGFrameInfo)
    case failure(JLICoreFailure)
    var failureValue: JLICoreFailure {
        switch self {
        case .failure(let failure): return failure
        case .success: preconditionFailure("Expected an already-checked failure")
        }
    }
}

enum JPEGScanHeaderOutcome {
    case success(JPEGScanHeader)
    case failure(JLICoreFailure)
    var failureValue: JLICoreFailure {
        switch self {
        case .failure(let failure): return failure
        case .success: preconditionFailure("Expected an already-checked failure")
        }
    }
}

enum JPEGQuantTablesOutcome {
    case success([(id: Int, values: [Int])])
    case failure(JLICoreFailure)
    var failureValue: JLICoreFailure {
        switch self {
        case .failure(let failure): return failure
        case .success: preconditionFailure("Expected an already-checked failure")
        }
    }
}

enum JPEGHuffmanTablesOutcome {
    case success([(tableClass: Int, tableId: Int, table: HuffmanTable)])
    case failure(JLICoreFailure)
    var failureValue: JLICoreFailure {
        switch self {
        case .failure(let failure): return failure
        case .success: preconditionFailure("Expected an already-checked failure")
        }
    }
}

enum JPEGBytesOutcome {
    case success([UInt8])
    case failure(JLICoreFailure)
    var failureValue: JLICoreFailure {
        switch self {
        case .failure(let failure): return failure
        case .success: preconditionFailure("Expected an already-checked failure")
        }
    }
}

// MARK: - Marker Reader

/// Reads and parses JPEG marker segments from a byte buffer.
struct MarkerReader {
    private let data: JPEGByteView
    private let callerStorage: JPEGParseCapture?
    private var offset: Int = 0
    private var cancellation: JLICancellation = .never
    private var nextCancellationCheckpoint = 65_536

    init(data: [UInt8]) {
        self.data = JPEGByteView(data)
        self.callerStorage = nil
    }

    init(borrowing data: UnsafeRawBufferPointer, storage: JPEGParseCapture, cancellation: JLICancellation = .never) {
        self.data = JPEGByteView(borrowing: data); callerStorage = storage; self.cancellation = cancellation
    }

    mutating func parse() throws -> ParsedJPEG {
        switch parseCore() {
        case .success(let value): return value
        case .failure(let failure): throw failure.compatibilityError
        }
    }
    mutating func readInfo() throws -> JLIJPEGInfo { try jliCompatibility { readInfoCore() } }

    /// Reads JPEG info without full decode.
    mutating func readInfoCore() -> JLICoreOutcome<JLIJPEGInfo> {
        if case .failure(let failure) = validateSOI() { return .failure(failure) }

        var frameInfo = JPEGFrameSlot.none

        while offset < data.count - 1 {
            let coreOutcome1 = nextMarker()
            guard case .success(let coreValue1) = coreOutcome1 else { return .failure(coreOutcome1.failureValue) }
            guard let marker = coreValue1 else { break }

            switch marker {
            case JPEGMarker.sof0, JPEGMarker.sof1, JPEGMarker.sof2, JPEGMarker.sof3:
                // SOF0 baseline + SOF1 extended sequential decode identically
                // (both Huffman sequential); SOF1 just permits 12-bit precision.
                let coreOutcome2 = readSOF(progressive: marker == JPEGMarker.sof2,
                                        lossless: marker == JPEGMarker.sof3)
                guard case .success(let coreValue2) = coreOutcome2 else { return .failure(coreOutcome2.failureValue) }
                frameInfo = .some(coreValue2)

            case JPEGMarker.eoi:
                break

            case JPEGMarker.sos:
                // Skip scan data for info-only parsing
                break

            default:
                if case .failure(let failure) = skipSegment() { return .failure(failure) }
            }

            if case .some = frameInfo {
                break  // We have what we need
            }
        }

        guard case .some(let frame) = frameInfo else {
            return .failure(JLICoreFailure(code: 100, kind: .invalidJPEG))
        }

        let subsampling = detectChromaSubsampling(frame.components)

        return .success(JLIJPEGInfo(
            width: frame.width,
            height: frame.height,
            componentCount: frame.components.count,
            bitsPerComponent: frame.precision,
            isProgressive: frame.isProgressive,
            isXYB: false,
            isExtendedPrecision: frame.precision > 8,
            chromaSubsampling: subsampling
        ))
    }

    /// Fully parses the JPEG stream, extracting all tables and scan data.
    mutating func parseCore() -> JPEGParseOutcome {
        if case .failure(let failure) = validateSOI() { return .failure(failure) }

        var sawEOI = false
        var adobeTransform: UInt8?
        var frameInfo = JPEGFrameSlot.none
        var quantTables = callerStorage == nil ? [[Int]](repeating: [Int](repeating: 0, count: 64), count: 4) : []
        var huffDC = [Int: HuffmanTable]()
        var huffAC = [Int: HuffmanTable]()
        var scans = callerStorage?.records.scanStorage() ?? JPEGStorageArray<JPEGScanData>()
        var restartInterval: Int = 0
        var exifData: [UInt8]? = nil
        var iccChunks: [Int: [UInt8]] = [:]   // sequence number → chunk payload

        markers: while offset < data.count - 1 {
            if callerStorage != nil { if case .failure(let failure) = cancellation.check() { return .failure(failure) } }
            let coreOutcome1 = nextMarker()
            guard case .success(let coreValue1) = coreOutcome1 else { return .failure(coreOutcome1.failureValue) }
            guard let marker = coreValue1 else { break }

            switch marker {
            case JPEGMarker.sof0, JPEGMarker.sof1, JPEGMarker.sof2, JPEGMarker.sof3:
                // SOF0 baseline + SOF1 extended sequential decode identically
                // (both Huffman sequential); SOF1 just permits 12-bit precision.
                guard case .none = frameInfo else { return .failure(JLICoreFailure(code: 101, kind: .decoding)) }
                let coreOutcome2 = readSOF(progressive: marker == JPEGMarker.sof2,
                                        lossless: marker == JPEGMarker.sof3)
                guard case .success(let coreValue2) = coreOutcome2 else { return .failure(coreOutcome2.failureValue) }
                frameInfo = .some(coreValue2)

            case JPEGMarker.dqt:
                let coreOutcome3 = readDQT()
                guard case .success(let tables) = coreOutcome3 else { return .failure(coreOutcome3.failureValue) }
                for (id, values) in tables {
                    quantTables[id] = values
                }

            case JPEGMarker.dht:
                let coreOutcome4 = readDHT()
                guard case .success(let tables) = coreOutcome4 else { return .failure(coreOutcome4.failureValue) }
                for (tableClass, tableId, table) in tables {
                    if tableClass == 0 {
                        huffDC[tableId] = table
                    } else {
                        huffAC[tableId] = table
                    }
                }

            case JPEGMarker.dri:
                // Length=4, then 2-byte restart interval.
                let coreOutcome5 = readUInt16()
                guard case .success(let coreValue5) = coreOutcome5 else { return .failure(coreOutcome5.failureValue) }
                guard coreValue5 == 4 else { return .failure(JLICoreFailure(code: 102, kind: .decoding)) }
                let coreOutcome6 = readUInt16()
                guard case .success(let coreValue6) = coreOutcome6 else { return .failure(coreOutcome6.failureValue) }
                restartInterval = Int(coreValue6)

            case JPEGMarker.sos:
                if let callerStorage, scans.count >= callerStorage.maximumScans {
                    return .failure(JLICoreFailure(code: 103, kind: .unsupported))
                }
                let coreOutcome7 = readSOS()
                guard case .success(let scanHeader) = coreOutcome7 else { return .failure(coreOutcome7.failureValue) }
                let coreOutcome8 = readEntropyRange()
                guard case .success(let entropyRange) = coreOutcome8 else { return .failure(coreOutcome8.failureValue) }
                if let callerStorage {
                    if case .failure(let failure) = callerStorage.scan(scanHeader, frame: frameInfo, entropy: entropyRange, restartInterval: restartInterval) { return .failure(failure) }
                }
                let entropyData = callerStorage == nil ? Array(data[entropyRange]) : []
                // Snapshot the tables active right now (progressive redefines them).
                scans.append(JPEGScanData(
                    header: scanHeader, entropyData: entropyData,
                    dcTables: huffDC, acTables: huffAC
                ))
                callerStorage?.records.didAppendScan()

            case JPEGMarker.eoi:
                sawEOI = true
                guard offset == data.count || (offset % 2 == 1 && offset + 1 == data.count && data[offset] == 0) else {
                    return .failure(JLICoreFailure(code: 104, kind: .decoding))
                }
                break markers

            case 0xee:
                if let callerStorage {
                    let coreOutcome9 = readSegmentRange()
                    guard case .success(let range) = coreOutcome9 else { return .failure(coreOutcome9.failureValue) }
                    callerStorage.application(marker: marker, range: range, input: data)
                    continue
                }
                let coreOutcome10 = readSegmentBytes()
                guard case .success(let segment) = coreOutcome10 else { return .failure(coreOutcome10.failureValue) }
                if segment.count >= 12 && Array(segment.prefix(5)) == [65, 100, 111, 98, 101] {
                    adobeTransform = segment[11]
                }

            case JPEGMarker.app1:
                if let callerStorage {
                    let coreOutcome11 = readSegmentRange()
                    guard case .success(let range) = coreOutcome11 else { return .failure(coreOutcome11.failureValue) }
                    callerStorage.application(marker: marker, range: range, input: data)
                    continue
                }
                // Exif: "Exif\0\0" identifier then the TIFF payload we preserve.
                let coreOutcome12 = readSegmentBytes()
                guard case .success(let seg) = coreOutcome12 else { return .failure(coreOutcome12.failureValue) }
                let exifID: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]
                if exifData == nil, seg.count >= 6, Array(seg[0..<6]) == exifID {
                    exifData = Array(seg[6...])
                }

            case JPEGMarker.app2:
                if let callerStorage {
                    let coreOutcome13 = readSegmentRange()
                    guard case .success(let range) = coreOutcome13 else { return .failure(coreOutcome13.failureValue) }
                    callerStorage.application(marker: marker, range: range, input: data)
                    continue
                }
                // ICC: "ICC_PROFILE\0" (12) + seq (1-based) + count, then a chunk
                // of the profile. Accumulate by sequence number; reassemble below.
                let coreOutcome14 = readSegmentBytes()
                guard case .success(let seg) = coreOutcome14 else { return .failure(coreOutcome14.failureValue) }
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
                if case .failure(let failure) = skipSegment() { return .failure(failure) }
            }
        }

        guard sawEOI else { return .failure(JLICoreFailure(code: 105, kind: .decoding)) }

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

        guard case .some(let frame) = frameInfo else {
            return .failure(JLICoreFailure(code: 106, kind: .invalidJPEG))
        }

        return .success(ParsedJPEG(
            frameInfo: frame,
            quantTables: quantTables,
            huffmanDCTables: huffDC,
            huffmanACTables: huffAC,
            scans: scans,
            restartInterval: restartInterval,
            iccProfile: iccProfile,
            exif: exifData, adobeTransform: adobeTransform
        ))
    }

    // MARK: - Private Parsing Methods

    private mutating func segmentEnd(minimumPayload: Int) -> JLICoreOutcome<Int> {
        let coreOutcome1 = readUInt16()
        guard case .success(let coreValue1) = coreOutcome1 else { return .failure(coreOutcome1.failureValue) }
        let payload = Int(coreValue1) - 2
        guard payload >= minimumPayload, payload <= data.count - offset else {
            return .failure(JLICoreFailure(code: 107, kind: .decoding))
        }
        return .success(offset + payload)
    }

    private mutating func validateSOI() -> JLICoreOutcome<Void> {
        guard data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 else {
            return .failure(JLICoreFailure(code: 108, kind: .invalidJPEG))
        }
        offset = 2
        return .success(())
    }

    /// Reads the next marker byte, skipping padding 0xFF bytes.
    private mutating func nextMarker() -> JLICoreOutcome<UInt8?> {
        while offset < data.count {
            if case .failure(let failure) = checkCancellation() { return .failure(failure) }
            if data[offset] == 0xFF {
                offset += 1
                // Skip padding 0xFF bytes
                while offset < data.count && data[offset] == 0xFF {
                    if case .failure(let failure) = checkCancellation() { return .failure(failure) }
                    offset += 1
                }
                if offset < data.count && data[offset] != 0x00 {
                    let marker = data[offset]
                    offset += 1
                    return .success(marker)
                }
            } else {
                offset += 1
            }
        }
        return .success(nil)
    }

    /// Reads the segment length and skips past the segment data.
    private mutating func skipSegment() -> JLICoreOutcome<Void> {
        let coreOutcome1 = readUInt16()
        guard case .success(let length) = coreOutcome1 else { return .failure(coreOutcome1.failureValue) }
        let skip = Int(length) - 2
        guard skip >= 0, offset + skip <= data.count else {
            return .failure(JLICoreFailure(code: 109, kind: .decoding))
        }
        offset += skip
        return .success(())
    }

    /// Reads the segment length and returns the segment's payload bytes (the
    /// `length − 2` bytes after the length field), advancing past them. Used to
    /// capture APP1/APP2 metadata segments.
    private mutating func readSegmentBytes() -> JPEGBytesOutcome {
        let coreOutcome1 = readUInt16()
        guard case .success(let length) = coreOutcome1 else { return .failure(coreOutcome1.failureValue) }
        let n = Int(length) - 2
        guard n >= 0, offset + n <= data.count else {
            return .failure(JLICoreFailure(code: 110, kind: .decoding))
        }
        let bytes = Array(data[offset..<offset + n])
        offset += n
        return .success(bytes)
    }

    private mutating func readSegmentRange() -> JLICoreOutcome<Range<Int>> {
        let coreOutcome1 = segmentEnd(minimumPayload: 0)
        guard case .success(let end) = coreOutcome1 else { return .failure(coreOutcome1.failureValue) }
        let start = offset
        offset = end
        return .success(start..<end)
    }

    /// Reads a SOF (Start of Frame) marker.
    private mutating func readSOF(progressive: Bool, lossless: Bool = false) -> JPEGFrameOutcome {
        let coreOutcome1 = segmentEnd(minimumPayload: 6)
        guard case .success(let endOffset) = coreOutcome1 else { return .failure(coreOutcome1.failureValue) }

        let coreOutcome2 = readByte()
        guard case .success(let coreValue2) = coreOutcome2 else { return .failure(coreOutcome2.failureValue) }
        let precision = Int(coreValue2)
        let coreOutcome3 = readUInt16()
        guard case .success(let coreValue3) = coreOutcome3 else { return .failure(coreOutcome3.failureValue) }
        let height = Int(coreValue3)
        let coreOutcome4 = readUInt16()
        guard case .success(let coreValue4) = coreOutcome4 else { return .failure(coreOutcome4.failureValue) }
        let width = Int(coreValue4)
        let coreOutcome5 = readByte()
        guard case .success(let coreValue5) = coreOutcome5 else { return .failure(coreOutcome5.failureValue) }
        let numComponents = Int(coreValue5)
        if let callerStorage, !callerStorage.accepts(componentCount: numComponents) {
            return .failure(JLICoreFailure(code: 111, kind: .unsupported))
        }

        guard endOffset - offset == numComponents * 3 else { return .failure(JLICoreFailure(code: 112, kind: .decoding)) }
        var components = callerStorage?.records.frameStorage() ?? JPEGStorageArray<JPEGComponentInfo>()
        for _ in 0..<numComponents {
            let coreOutcome6 = readByte()
            guard case .success(let id) = coreOutcome6 else { return .failure(coreOutcome6.failureValue) }
            let coreOutcome7 = readByte()
            guard case .success(let sampling) = coreOutcome7 else { return .failure(coreOutcome7.failureValue) }
            let coreOutcome8 = readByte()
            guard case .success(let quantId) = coreOutcome8 else { return .failure(coreOutcome8.failureValue) }
            components.append(JPEGComponentInfo(
                id: id,
                horizontalSampling: Int(sampling >> 4),
                verticalSampling: Int(sampling & 0x0F),
                quantTableIndex: Int(quantId)
            ))
        }

        offset = endOffset
        return .success(JPEGFrameInfo(
            precision: precision,
            width: width,
            height: height,
            components: components,
            isProgressive: progressive,
            isLossless: lossless
        ))
    }

    /// Reads a DQT (Define Quantization Table) marker.
    private mutating func readDQT() -> JPEGQuantTablesOutcome {
        let coreOutcome1 = segmentEnd(minimumPayload: 0)
        guard case .success(let endOffset) = coreOutcome1 else { return .failure(coreOutcome1.failureValue) }
        var tables = [(id: Int, values: [Int])]()

        while offset < endOffset {
            let coreOutcome2 = readByte()
            guard case .success(let info) = coreOutcome2 else { return .failure(coreOutcome2.failureValue) }
            let precision = Int(info >> 4)
            let tableId = Int(info & 0x0F)
            // T.81: Pq (precision) is 0 (8-bit) or 1 (16-bit); Tq (table id) is
            // 0–3. A corrupted DQT length desyncs parsing and feeds garbage here,
            // so reject out-of-range ids/precision rather than indexing past the
            // 4-slot quant-table array.
            guard precision == 0 || precision == 1 else {
                return .failure(JLICoreFailure(code: 113, kind: .decoding, detail0: Int(precision)))
            }
            guard tableId <= 3 else {
                return .failure(JLICoreFailure(code: 114, kind: .decoding, detail0: Int(tableId)))
            }

            guard endOffset - offset >= 64 * (precision + 1) else { return .failure(JLICoreFailure(code: 115, kind: .decoding)) }
            if let callerStorage {
                let start = offset
                for _ in 0..<64 {
                    if precision == 0 {
                        if case .failure(let failure) = readByte() { return .failure(failure) }
                    } else {
                        if case .failure(let failure) = readUInt16() { return .failure(failure) }
                    }
                }
                callerStorage.quantization(id: tableId, precision: precision, range: start..<offset)
                continue
            }
            var values = [Int](repeating: 0, count: 64)
            for i in 0..<64 {
                if precision == 0 {
                    let coreOutcome5 = readByte()
                    guard case .success(let coreValue5) = coreOutcome5 else { return .failure(coreOutcome5.failureValue) }
                    values[i] = Int(coreValue5)
                } else {
                    let coreOutcome6 = readUInt16()
                    guard case .success(let coreValue6) = coreOutcome6 else { return .failure(coreOutcome6.failureValue) }
                    values[i] = Int(coreValue6)
                }
            }
            tables.append((id: tableId, values: values))
        }

        return .success(tables)
    }

    /// Reads a DHT (Define Huffman Table) marker.
    private mutating func readDHT() -> JPEGHuffmanTablesOutcome {
        let coreOutcome1 = segmentEnd(minimumPayload: 0)
        guard case .success(let endOffset) = coreOutcome1 else { return .failure(coreOutcome1.failureValue) }
        var tables = [(tableClass: Int, tableId: Int, table: HuffmanTable)]()

        while offset < endOffset {
            let coreOutcome2 = readByte()
            guard case .success(let info) = coreOutcome2 else { return .failure(coreOutcome2.failureValue) }
            let tableClass = Int(info >> 4)
            let tableId = Int(info & 0x0F)

            guard endOffset - offset >= 16 else { return .failure(JLICoreFailure(code: 116, kind: .decoding)) }
            let bitsStart = offset
            var totalValues = 0
            var codeSpace = 0
            for len in 1...16 {
                let coreOutcome3 = readByte()
                guard case .success(let coreValue3) = coreOutcome3 else { return .failure(coreOutcome3.failureValue) }
                let count = Int(coreValue3)
                totalValues += count
                codeSpace += count
                guard codeSpace <= (1 << len) else {
                    return .failure(JLICoreFailure(code: 117, kind: .decoding, detail0: Int(len)))
                }
                codeSpace <<= 1
            }
            guard totalValues <= 256 else {
                return .failure(JLICoreFailure(code: 118, kind: .decoding, detail0: Int(totalValues)))
            }
            guard endOffset - offset >= totalValues else { return .failure(JLICoreFailure(code: 119, kind: .decoding)) }
            let valuesStart = offset
            for _ in 0..<totalValues {
                if case .failure(let failure) = readByte() { return .failure(failure) }
            }
            if let callerStorage {
                callerStorage.table(isDC: tableClass == 0, id: tableId, bits: bitsStart, values: valuesStart, count: totalValues)
                continue
            }
            let bits = Array(data[bitsStart..<(bitsStart + 16)])
            let values = Array(data[valuesStart..<(valuesStart + totalValues)])
            let table = HuffmanTable(bits: bits, values: values)
            tables.append((tableClass: tableClass, tableId: tableId, table: table))
        }

        return .success(tables)
    }

    /// Reads a SOS (Start of Scan) marker header.
    private mutating func readSOS() -> JPEGScanHeaderOutcome {
        let coreOutcome1 = segmentEnd(minimumPayload: 4)
        guard case .success(let endOffset) = coreOutcome1 else { return .failure(coreOutcome1.failureValue) }

        let coreOutcome2 = readByte()
        guard case .success(let coreValue2) = coreOutcome2 else { return .failure(coreOutcome2.failureValue) }
        let numComponents = Int(coreValue2)
        if let callerStorage, !callerStorage.accepts(componentCount: numComponents) {
            return .failure(JLICoreFailure(code: 120, kind: .unsupported))
        }
        guard endOffset - offset == numComponents * 2 + 3 else { return .failure(JLICoreFailure(code: 121, kind: .decoding)) }
        var components = callerStorage?.records.componentStorage() ?? JPEGStorageArray<JPEGScanComponent>()

        for _ in 0..<numComponents {
            let coreOutcome3 = readByte()
            guard case .success(let selector) = coreOutcome3 else { return .failure(coreOutcome3.failureValue) }
            let coreOutcome4 = readByte()
            guard case .success(let tableIds) = coreOutcome4 else { return .failure(coreOutcome4.failureValue) }
            components.append((
                componentSelector: selector,
                dcTableId: Int(tableIds >> 4),
                acTableId: Int(tableIds & 0x0F)
            ))
        }

        let coreOutcome5 = readByte()
        guard case .success(let coreValue5) = coreOutcome5 else { return .failure(coreOutcome5.failureValue) }
        let spectralStart = Int(coreValue5)
        let coreOutcome6 = readByte()
        guard case .success(let coreValue6) = coreOutcome6 else { return .failure(coreOutcome6.failureValue) }
        let spectralEnd = Int(coreValue6)
        let coreOutcome7 = readByte()
        guard case .success(let successive) = coreOutcome7 else { return .failure(coreOutcome7.failureValue) }

        return .success(JPEGScanHeader(
            components: components,
            spectralStart: spectralStart,
            spectralEnd: spectralEnd,
            successiveApproxHigh: Int(successive >> 4),
            successiveApproxLow: Int(successive & 0x0F)
        ))
    }

    /// Slices the entropy-coded segment between SOS and the next non-RST marker.
    ///
    /// The returned buffer is byte-for-byte identical to what the encoder wrote, including
    /// stuffed `0xFF 0x00` pairs **and** restart markers (`0xFF 0xD0`–`0xFF 0xD7`).
    /// `BitReader` is the single point that performs unstuffing, and the decoder consumes
    /// restart markers explicitly at known MCU boundaries via `skipRestartMarker`.
    private mutating func readEntropyRange() -> JLICoreOutcome<Range<Int>> {
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
        do {
            let p = data
            while pos < n {
                if callerStorage != nil, pos >= nextCheckpoint {
                    if case .failure(let failure) = cancellation.check() { return .failure(failure) }
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
        return .success(start..<pos)
    }

    // MARK: - Byte Reading Primitives

    private mutating func checkCancellation() -> JLICoreOutcome<Void> {
        if callerStorage != nil, offset >= nextCancellationCheckpoint {
            if case .failure(let failure) = cancellation.check() { return .failure(failure) }
            nextCancellationCheckpoint = offset > Int.max - 65_536 ? Int.max : offset + 65_536
        }
        return .success(())
    }

    private mutating func readByte() -> JLICoreOutcome<UInt8> {
        if case .failure(let failure) = checkCancellation() { return .failure(failure) }
        guard offset < data.count else {
            return .failure(JLICoreFailure(code: 122, kind: .decoding))
        }
        let byte = data[offset]
        offset += 1
        return .success(byte)
    }

    private mutating func readUInt16() -> JLICoreOutcome<UInt16> {
        let coreOutcome1 = readByte()
        guard case .success(let high) = coreOutcome1 else { return .failure(coreOutcome1.failureValue) }
        let coreOutcome2 = readByte()
        guard case .success(let low) = coreOutcome2 else { return .failure(coreOutcome2.failureValue) }
        return .success((UInt16(high) << 8) | UInt16(low))
    }

    // MARK: - Helpers

    private func detectChromaSubsampling(_ components: JPEGStorageArray<JPEGComponentInfo>) -> JLIChromaSubsampling {
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
