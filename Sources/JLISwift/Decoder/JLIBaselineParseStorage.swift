// SPDX-License-Identifier: Apache-2.0
/// Fixed descriptors for the canonical parser's RGB sequential storage policy.
final class JLIBaselineParseStorage: JPEGParseCapture {
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
    private(set) var scanCount = 0
    private var seenComponents: UInt8 = 0
    private(set) var adobeTransform: UInt8?
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
        precondition(offset <= Self.byteCount)
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
            adobeTransform = input[start + 11]
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
    func scan(_ scan: JPEGScanHeader, frame: JPEGFrameInfo?, entropy: Range<Int>, restartInterval: Int) throws {
        guard let frame, !frame.isLossless, !frame.isProgressive, frame.precision == 8,
              frame.components.count == 3, scan.spectralStart == 0, scan.spectralEnd == 63,
              scan.successiveApproxHigh == 0, scan.successiveApproxLow == 0 else {
            throw JLIError.unsupportedJPEGFeature("Caller-storage RGB requires sequential 8-bit JPEG")
        }
        for component in scan.components {
            guard let index = frame.components.firstIndex(where: { $0.id == component.componentSelector }),
                  seenComponents & (1 << index) == 0 else {
                throw JLIError.decodingFailed("Repeated or unknown sequential scan component")
            }
            guard (0..<4).contains(frame.components[index].quantTableIndex) else {
                throw JLIError.decodingFailed("Invalid quantization table selector")
            }
            selectedQuantization[index] = quantization[frame.components[index].quantTableIndex]
            seenComponents |= 1 << index
            snapshots[scanCount * 6 + index * 2] = tables[component.dcTableId]
            snapshots[scanCount * 6 + index * 2 + 1] = tables[16 + component.acTableId]
        }
        restartIntervals[scanCount] = restartInterval
        entropyRanges[scanCount] = entropy
        scanCount += 1
    }
    func validateCoverage() throws {
        guard seenComponents == 7 else { throw JLIError.decodingFailed("Incomplete sequential component scans") }
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
        let expected = XYBICCProfile.data
        guard total == expected.count else { return false }
        var position = 0
        for index in 1...chunks {
            let range = iccRanges[index]
            guard range.lowerBound >= 0 else { return false }
            for byte in range {
                guard input[byte] == expected[position] else { return false }
                position += 1
            }
        }
        return true
    }
}
