// SPDX-License-Identifier: Apache-2.0
/// Only scalar descriptors are retained by the canonical parser's caller-storage
/// lossless policy. Encoded tables/entropy remain borrowed ranges.
enum JPEGParseCapture {
    case lossless(JLILosslessParseStorage), baseline(JLIBaselineParseStorage)
    var maximumScans: Int { switch self { case .lossless: 1; case .baseline: 3 } }
    var records: JPEGCallerRecords { switch self { case .lossless(let s): s.records; case .baseline(let s): s.records } }
    func accepts(componentCount: Int) -> Bool { switch self { case .lossless: componentCount == 1; case .baseline: (1...3).contains(componentCount) } }
    func table(isDC: Bool, id: Int, bits: Int, values: Int, count: Int) {
        switch self { case .lossless(let s): s.table(isDC: isDC, id: id, bits: bits, values: values, count: count)
        case .baseline(let s): s.table(isDC: isDC, id: id, bits: bits, values: values, count: count) }
    }
    func quantization(id: Int, precision: Int, range: Range<Int>) {
        if case .baseline(let s) = self { s.quantization(id: id, precision: precision, range: range) }
    }
    func application(marker: UInt8, range: Range<Int>, input: JPEGByteView) {
        if case .baseline(let s) = self { s.application(marker: marker, range: range, input: input) }
    }
    func scan(_ scan: JPEGScanHeader, frame: JPEGFrameSlot, entropy: Range<Int>, restartInterval: Int) -> JLICoreOutcome<Void> {
        switch self {
        case .lossless(let storage): return storage.scan(scan, frame: frame, entropy: entropy, restartInterval: restartInterval)
        case .baseline(let storage): return storage.scan(scan, frame: frame, entropy: entropy, restartInterval: restartInterval)
        }
    }
}

struct JLILosslessParseStorage {
    static let headerByteCount = 5120
    let records: JPEGCallerRecords
    private let state: UnsafeMutablePointer<State>
    private struct State {
        var selected = Descriptor()
        var selectedID = 0
        var entropy = 0..<0
        var restartInterval = 0
    }
    let maximumScans = 1
    func accepts(componentCount: Int) -> Bool { componentCount == 1 }
    func quantization(id: Int, precision: Int, range: Range<Int>) {}
    func application(marker: UInt8, range: Range<Int>, input: JPEGByteView) {}
    struct Descriptor {
        var bits = 0
        var values = 0
        var count = -1
    }
    let descriptors: UnsafeMutableBufferPointer<Descriptor>
    var selected: Descriptor { state.pointee.selected }
    var selectedID: Int { state.pointee.selectedID }
    var entropy: Range<Int> { state.pointee.entropy }
    var restartInterval: Int { state.pointee.restartInterval }
    init(workspace: UnsafeMutableRawBufferPointer) {
        precondition(workspace.count >= Self.headerByteCount)
        descriptors = UnsafeMutableRawBufferPointer(rebasing: workspace[..<(16 * MemoryLayout<Descriptor>.stride)]).bindMemory(to: Descriptor.self)
        descriptors.initialize(repeating: Descriptor())
        state = (workspace.baseAddress! + 512).bindMemory(to: State.self, capacity: 1)
        precondition(512 + MemoryLayout<State>.stride <= 1024)
        state.initialize(to: State())
        records = JPEGCallerRecords(UnsafeMutableRawBufferPointer(rebasing: workspace[1024..<Self.headerByteCount]))
    }
    func table(isDC: Bool, id: Int, bits: Int, values: Int, count: Int) {
        guard isDC else { return }
        descriptors[id] = Descriptor(bits: bits, values: values, count: count)
    }
    func scan(_ scan: JPEGScanHeader, frame: JPEGFrameSlot, entropy: Range<Int>, restartInterval: Int) -> JLICoreOutcome<Void> {
        guard case .some(let frame) = frame, frame.isLossless, frame.components.count == 1 else {
            return .failure(JLICoreFailure(code: 133, kind: .unsupported))
        }
        let selector = scan.components.first { $0.componentSelector == frame.components[0].id }
        state.pointee.selectedID = selector?.dcTableId ?? 0
        state.pointee.selected = descriptors[selectedID]
        state.pointee.entropy = entropy
        state.pointee.restartInterval = restartInterval
        return .success(())
    }
}

protocol LosslessSampleStorage {
    subscript(index: Int) -> Int32 { get nonmutating set }
}
struct LosslessInt32Samples: LosslessSampleStorage {
    let pointer: UnsafeMutablePointer<Int32>
    subscript(index: Int) -> Int32 {
        get { pointer[index] }
        nonmutating set { pointer[index] = newValue }
    }
}

/// The canonical kernel still computes Int32 predictions/modulo-65536 samples;
/// only their storage changes. Final point-transform serialization is in place.
struct LosslessLittleEndianSamples: LosslessSampleStorage {
    let bytes: UnsafeMutableRawBufferPointer
    subscript(index: Int) -> Int32 {
        get { Int32(bytes[index * 2]) | Int32(bytes[index * 2 + 1]) << 8 }
        nonmutating set {
            bytes[index * 2] = UInt8(truncatingIfNeeded: newValue)
            bytes[index * 2 + 1] = UInt8(truncatingIfNeeded: newValue >> 8)
        }
    }
}

/// Concrete ownership carrier for the shared lossless validation result.
enum JLILosslessParametersOutcome {
    case success((predictor: Int, pointTransform: Int, scan: JPEGScanData))
    case failure(JLICoreFailure)
    var failureValue: JLICoreFailure {
        switch self {
        case .failure(let failure): return failure
        case .success: preconditionFailure("Expected an already-checked failure")
        }
    }
}
