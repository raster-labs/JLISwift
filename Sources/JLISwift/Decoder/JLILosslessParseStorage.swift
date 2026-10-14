// SPDX-License-Identifier: Apache-2.0
/// Only scalar descriptors are retained by the canonical parser's caller-storage
/// lossless policy. Encoded tables/entropy remain borrowed ranges.
protocol JPEGParseCapture: AnyObject {
    var maximumScans: Int { get }
    func accepts(componentCount: Int) -> Bool
    func table(isDC: Bool, id: Int, bits: Int, values: Int, count: Int)
    func quantization(id: Int, precision: Int, range: Range<Int>)
    func application(marker: UInt8, range: Range<Int>, input: JPEGByteView)
    func scan(_ scan: JPEGScanHeader, frame: JPEGFrameInfo?, entropy: Range<Int>, restartInterval: Int) throws
}

final class JLILosslessParseStorage: JPEGParseCapture {
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
    private(set) var selected = Descriptor()
    private(set) var selectedID = 0
    private(set) var entropy = 0..<0
    init(descriptors: UnsafeMutableBufferPointer<Descriptor>) {
        self.descriptors = descriptors
        descriptors.initialize(repeating: Descriptor())
    }
    func table(isDC: Bool, id: Int, bits: Int, values: Int, count: Int) {
        guard isDC else { return }
        descriptors[id] = Descriptor(bits: bits, values: values, count: count)
    }
    func scan(_ scan: JPEGScanHeader, frame: JPEGFrameInfo?, entropy: Range<Int>, restartInterval: Int) throws {
        guard let frame, frame.isLossless, frame.components.count == 1 else {
            throw JLIError.unsupportedJPEGFeature("Caller-storage lossless decoding requires a monochrome SOF3 frame")
        }
        let selector = scan.components.first { $0.componentSelector == frame.components[0].id }
        selectedID = selector?.dcTableId ?? 0
        selected = descriptors[selectedID]
        self.entropy = entropy
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
