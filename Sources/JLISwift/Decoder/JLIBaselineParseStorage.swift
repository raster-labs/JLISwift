// SPDX-License-Identifier: Apache-2.0
/// Fixed descriptors for the canonical parser's RGB sequential storage policy.
struct JLIBaselineParseStorage {
    let records: JPEGCallerRecords
    private let state: UnsafeMutablePointer<State>
    private struct State {
        var scanCount = 0
        var seenComponents: UInt8 = 0
        var adobeTransform: UInt8?
    }
    typealias Descriptor = JLILosslessParseStorage.Descriptor
    static let byteCount = 16_384
    let maximumScans = 3
    private let tables: UnsafeMutableBufferPointer<Descriptor>
    private let snapshots: UnsafeMutableBufferPointer<Descriptor>
    private let quantization: UnsafeMutableBufferPointer<Descriptor>
    private let selectedQuantization: UnsafeMutableBufferPointer<Descriptor>
    private let restartIntervals: UnsafeMutableBufferPointer<Int>
    private let entropyRanges: UnsafeMutableBufferPointer<Range<Int>>
    private let iccRanges: UnsafeMutableBufferPointer<Range<Int>>
    let huffmanViews: UnsafeMutableBufferPointer<BorrowedHuffmanTable>
    private let dct: UnsafeMutableBufferPointer<Float>
    private let transposedDCT: UnsafeMutableBufferPointer<Float>
    private let zigzag: UnsafeMutableBufferPointer<Int>
    private let inverseZigzag: UnsafeMutableBufferPointer<Int>
    var scanCount: Int { state.pointee.scanCount }
    var seenComponents: UInt8 { state.pointee.seenComponents }
    var adobeTransform: UInt8? { state.pointee.adobeTransform }
    func accepts(componentCount: Int) -> Bool { (1...3).contains(componentCount) }

    init(workspace: UnsafeMutableRawBufferPointer) {
        precondition(workspace.count >= Self.byteCount)
        var offset = 0
        func buffer<T>(_ type: T.Type, _ count: Int) -> UnsafeMutableBufferPointer<T> {
            let start = offset
            offset += MemoryLayout<T>.stride * count
            return UnsafeMutableRawBufferPointer(rebasing: workspace[start..<offset]).bindMemory(to: T.self)
        }
        tables = buffer(Descriptor.self, 32); snapshots = buffer(Descriptor.self, 18)
        quantization = buffer(Descriptor.self, 4); selectedQuantization = buffer(Descriptor.self, 3)
        restartIntervals = buffer(Int.self, 3); restartIntervals.initialize(repeating: 0)
        selectedQuantization.initialize(repeating: Descriptor()); entropyRanges = buffer(Range<Int>.self, 3)
        iccRanges = buffer(Range<Int>.self, 256)
        tables.initialize(repeating: Descriptor()); snapshots.initialize(repeating: Descriptor())
        quantization.initialize(repeating: Descriptor()); entropyRanges.initialize(repeating: 0..<0)
        iccRanges.initialize(repeating: -1..<0)
        // The existing header reservation admits these spans before parsing. On
        // supported 64-bit targets, descriptors + constants occupy 7,072 of 16,384 bytes.
        dct = buffer(Float.self, 64); transposedDCT = buffer(Float.self, 64)
        zigzag = buffer(Int.self, 64); inverseZigzag = buffer(Int.self, 64)
        state = buffer(State.self, 1).baseAddress!
        state.initialize(to: State())
        huffmanViews = buffer(BorrowedHuffmanTable.self, 6)
        precondition(offset <= 8192)
        records = JPEGCallerRecords(UnsafeMutableRawBufferPointer(rebasing: workspace[8192..<12288]))
    }

    /// Called only after full decode capacity admission. These pointers remain
    /// synchronous borrows of the header workspace; no table escapes in the result.
    func initializeReconstructionTables() -> AccelerateDSP.ReconstructionTables {
        AccelerateDSP.fillDCTMatrix(dct)
        AccelerateDSP.fillDCTTranspose(UnsafeBufferPointer(dct), into: transposedDCT)
        Quantization.fillZigzagOrder(zigzag)
        Quantization.fillInverseZigzagOrder(UnsafeBufferPointer(zigzag), into: inverseZigzag)
        guard let dctBase = dct.baseAddress, let transposedBase = transposedDCT.baseAddress,
              let zigzagBase = zigzag.baseAddress, let inverseBase = inverseZigzag.baseAddress else {
            preconditionFailure("Validated reconstruction table storage has no backing")
        }
        return AccelerateDSP.ReconstructionTables(dct: dctBase, transposedDCT: transposedBase,
            zigzag: zigzagBase, inverseZigzag: inverseBase)
    }
    func table(isDC: Bool, id: Int, bits: Int, values: Int, count: Int) {
        tables[(isDC ? 0 : 16) + id] = Descriptor(bits: bits, values: values, count: count)
    }
    func quantization(id: Int, precision: Int, range: Range<Int>) {
        quantization[id] = Descriptor(bits: precision, values: range.lowerBound, count: 64)
    }
    func application(marker: UInt8, range: Range<Int>, input: JPEGByteView) {
        let start = range.lowerBound
        if marker == 0xee, range.count >= 12,
           input[start] == 65, input[start + 1] == 100, input[start + 2] == 111,
           input[start + 3] == 98, input[start + 4] == 101 {
            state.pointee.adobeTransform = input[start + 11]
        }
        if marker == JPEGMarker.app2, range.count >= 14 {
            let identifier: StaticString = "ICC_PROFILE\0"
            let matches = identifier.withUTF8Buffer { id in (0..<12).allSatisfy { input[start + $0] == id[$0] } }
            if matches {
                let sequence = Int(input[start + 12])
                if iccRanges[sequence].lowerBound == -1 { iccRanges[sequence] = (start + 14)..<range.upperBound }
            }
        }
    }
    func scan(_ scan: JPEGScanHeader, frame: JPEGFrameSlot, entropy: Range<Int>, restartInterval: Int) -> JLICoreOutcome<Void> {
        guard case .some(let frame) = frame, !frame.isLossless, !frame.isProgressive, frame.precision == 8,
              frame.components.count == 3, scan.spectralStart == 0, scan.spectralEnd == 63,
              scan.successiveApproxHigh == 0, scan.successiveApproxLow == 0 else {
            return .failure(JLICoreFailure(code: 134, kind: .unsupported))
        }
        for component in scan.components {
            guard let index = frame.components.firstIndex(where: { $0.id == component.componentSelector }),
                  seenComponents & (1 << index) == 0 else {
                return .failure(JLICoreFailure(code: 135, kind: .decoding))
            }
            guard (0..<4).contains(frame.components[index].quantTableIndex) else {
                return .failure(JLICoreFailure(code: 136, kind: .decoding))
            }
            selectedQuantization[index] = quantization[frame.components[index].quantTableIndex]
            state.pointee.seenComponents |= 1 << index
            snapshots[scanCount * 6 + index * 2] = tables[component.dcTableId]
            snapshots[scanCount * 6 + index * 2 + 1] = tables[16 + component.acTableId]
        }
        restartIntervals[scanCount] = restartInterval
        entropyRanges[scanCount] = entropy
        state.pointee.scanCount += 1
        return .success(())
    }
    func validateCoverage() -> JLICoreOutcome<Void> {
        guard seenComponents == 7 else { return .failure(JLICoreFailure(code: 137, kind: .decoding)) }
        return .success(())
    }
    func entropy(_ scan: Int) -> Range<Int> { entropyRanges[scan] }
    func restartInterval(_ scan: Int) -> Int { restartIntervals[scan] }
    func descriptor(scan: Int, component: Int, isDC: Bool) -> Descriptor {
        snapshots[scan * 6 + component * 2 + (isDC ? 0 : 1)]
    }
    func quantizationValue(component: Int, zigzag: Int, input: UnsafeRawBufferPointer) -> Float {
        let descriptor = selectedQuantization[component]
        if descriptor.count == -1 { return 0 }
        let offset = descriptor.values + zigzag * (descriptor.bits + 1)
        return descriptor.bits == 0 ? Float(input[offset]) : Float(Int(input[offset]) * 256 + Int(input[offset + 1]))
    }
    func isXYB(input: UnsafeRawBufferPointer) -> Bool {
        if iccRanges[0].lowerBound != -1 { return false }
        var chunks = 0, total = 0
        for index in 1..<256 where iccRanges[index].lowerBound != -1 { chunks += 1; total += iccRanges[index].count }
        guard chunks > 0 else { return false }
        guard total == XYBICCProfile.count else { return false }
        var position = 0
        for index in 1...chunks {
            let range = iccRanges[index]
            guard range.lowerBound >= 0 else { return false }
            for byte in range {
                guard input[byte] == XYBICCProfile.byte(at: position) else { return false }
                position += 1
            }
        }
        return true
    }
}
