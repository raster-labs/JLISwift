// SPDX-License-Identifier: Apache-2.0
extension JLIDecoder {
    /// Scalar description of the pixel-only caller-storage lossless result.
    public struct LosslessMonochromeInfo: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let precision: Int
        public let pointTransform: Int
        /// Caller storage always contains unsigned, little-endian 16-bit samples.
        public var outputByteCount: Int { width * height * 2 }
    }

    /// Fixed raw scratch for table descriptors and the decode-only Huffman table.
    /// This excludes Swift runtime/control object allocations; it is a payload
    /// capacity contract. The caller supplies exclusive Int-aligned trivial storage.
    public static var losslessMonochromeWorkspaceByteCount: Int {
        16 * MemoryLayout<JLILosslessParseStorage.Descriptor>.stride + BorrowedHuffmanTable.byteCount
    }

    /// Fully parses a monochrome SOF3 stream with the canonical marker parser,
    /// borrowing encoded table and entropy spans. No metadata payload is returned.
    public func inspectLosslessMonochrome(_ encoded: UnsafeRawBufferPointer,
        workspace: UnsafeMutableRawBufferPointer,
        configuration: JLIDecoderConfiguration = .default) throws -> LosslessMonochromeInfo {
        try callerSpans(encoded, workspace: workspace, configuration: configuration)
        let storage = losslessStorage(workspace)
        var parser = MarkerReader(borrowing: encoded, storage: storage)
        let parsed = try parser.parse()
        return try losslessMonochromePlan(parsed, configuration: configuration)
    }

    /// Reconstructs directly in supplied little-endian UInt16 output using the
    /// existing prediction/Huffman kernel. All spans must be disjoint and remain
    /// alive for this synchronous call. Output must not be published on failure;
    /// cancellation or malformed entropy may leave partially written samples.
    /// Input/entropy/metadata and full-frame intermediate copies are avoided.
    public func decodeLosslessMonochrome(_ encoded: UnsafeRawBufferPointer,
        into output: UnsafeMutableRawBufferPointer, workspace: UnsafeMutableRawBufferPointer,
        configuration: JLIDecoderConfiguration = .default) throws -> LosslessMonochromeInfo {
        try callerSpans(encoded, workspace: workspace, configuration: configuration)
        guard !Self.callerSpansOverlap(encoded, UnsafeRawBufferPointer(output)),
              !Self.callerSpansOverlap(UnsafeRawBufferPointer(workspace), UnsafeRawBufferPointer(output)) else {
            throw JLIError.decodingFailed("Caller input, output and workspace overlap")
        }
        let storage = losslessStorage(workspace)
        var parser = MarkerReader(borrowing: encoded, storage: storage)
        let parsed = try parser.parse()
        let info = try losslessMonochromePlan(parsed, configuration: configuration)
        guard output.count >= info.outputByteCount else {
            throw JLIError.decodingFailed("Lossless output capacity is too small")
        }
        let plan = try Self.losslessParameters(frame: parsed.frameInfo, scans: parsed.scans, configuration: configuration)
        let tableOffset = 16 * MemoryLayout<JLILosslessParseStorage.Descriptor>.stride
        let tableWorkspace = UnsafeMutableRawBufferPointer(rebasing: workspace[tableOffset..<Self.losslessMonochromeWorkspaceByteCount])
        let descriptor = storage.selected
        let fallback = storage.selectedID == 1 ? StandardHuffmanTables.dcChrominanceDefinition : StandardHuffmanTables.dcLuminanceDefinition
        let table = BorrowedHuffmanTable(workspace: tableWorkspace,
            valueCount: descriptor.count >= 0 ? descriptor.count : fallback.count,
            bits: { descriptor.count >= 0 ? encoded[descriptor.bits + $0] : fallback.bit($0) },
            value: { descriptor.count >= 0 ? encoded[descriptor.values + $0] : fallback.value($0) })
        var reader = BitReader(borrowing: UnsafeRawBufferPointer(rebasing: encoded[storage.entropy]))
        let w = info.width, h = info.height
        let interval = parsed.restartInterval
        guard interval == 0 || interval % w == 0 else {
            throw JLIError.unsupportedJPEGFeature("Lossless restart interval is not a multiple of samples per row")
        }
        let rowsPerRegion = interval > 0 ? interval / w : h
        let regions = 1 + (h - 1) / rowsPerRegion
        let half = Int32(1 << (info.precision - 1 - info.pointTransform))
        for region in 0..<regions {
            try Task.checkCancellation()
            if region > 0 { try reader.skipRestartMarker(expectedIndex: (region - 1) & 7) }
            let row = region * rowsPerRegion
            let rows = min(rowsPerRegion, h - row)
            let start = row * w * 2, end = start + rows * w * 2
            let plane = LosslessLittleEndianSamples(bytes: UnsafeMutableRawBufferPointer(rebasing: output[start..<end]))
            try Self.losslessScanGrayInto(plane, width: w, height: rows, predictor: plan.predictor,
                half: half, table: table, reader: &reader, cancellable: true)
        }
        let samples = LosslessLittleEndianSamples(bytes: output)
        for index in 0..<(w * h) {
            if index & 0xFFFF == 0 { try Task.checkCancellation() }
            // Match existing output serialization, including <=8-bit clamp.
            let shifted = Int(samples[index]) << info.pointTransform
            samples[index] = Int32(info.precision <= 8 ? Int(UInt8(clamping: shifted)) : Int(UInt16(clamping: shifted)))
        }
        return info
    }

    private func losslessMonochromePlan(_ parsed: ParsedJPEG,
        configuration: JLIDecoderConfiguration) throws -> LosslessMonochromeInfo {
        let frame = parsed.frameInfo
        guard frame.isLossless, frame.components.count == 1 else {
            throw JLIError.unsupportedJPEGFeature("Caller-storage decoding requires monochrome SOF3")
        }
        guard configuration.outputPixelFormat == nil || configuration.outputPixelFormat == .uint16 else {
            throw JLIError.unsupportedJPEGFeature("Caller-storage output is always little-endian UInt16")
        }
        let plan = try Self.losslessParameters(frame: frame, scans: parsed.scans, configuration: configuration)
        let (pixels, overflow) = frame.width.multipliedReportingOverflow(by: frame.height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 2)
        guard !overflow, !byteOverflow, pixels <= configuration.maximumPixels,
              bytes <= configuration.maximumDecodedBytes else {
            throw JLIError.decodingFailed("Lossless frame exceeds pixel/byte limit")
        }
        guard configuration.outputColorModel == nil || configuration.outputColorModel == .grayscale else {
            throw JLIError.unsupportedJPEGFeature("Monochrome output requires grayscale interpretation")
        }
        return LosslessMonochromeInfo(width: frame.width, height: frame.height,
            precision: frame.precision, pointTransform: plan.pointTransform)
    }

    private func losslessStorage(_ workspace: UnsafeMutableRawBufferPointer) -> JLILosslessParseStorage {
        let count = 16 * MemoryLayout<JLILosslessParseStorage.Descriptor>.stride
        return JLILosslessParseStorage(descriptors:
            UnsafeMutableRawBufferPointer(rebasing: workspace[..<count]).bindMemory(to: JLILosslessParseStorage.Descriptor.self))
    }

    private func callerSpans(_ encoded: UnsafeRawBufferPointer, workspace: UnsafeMutableRawBufferPointer,
                             configuration: JLIDecoderConfiguration) throws {
        guard encoded.count <= configuration.maximumEncodedBytes,
              workspace.count >= Self.losslessMonochromeWorkspaceByteCount,
              let address = workspace.baseAddress,
              UInt(bitPattern: address) % UInt(MemoryLayout<Int>.alignment) == 0,
              !Self.callerSpansOverlap(encoded, UnsafeRawBufferPointer(workspace)) else {
            throw JLIError.decodingFailed("Invalid caller input or workspace capacity/alignment")
        }
        if let source = configuration.sourceColorModel, source != .rgb && source != .yCbCr {
            throw JLIError.unsupportedJPEGFeature("Unsupported JPEG source color interpretation")
        }
        try Task.checkCancellation()
    }

    internal static func callerSpansOverlap(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer) -> Bool {
        guard !a.isEmpty, !b.isEmpty, let x = a.baseAddress, let y = b.baseAddress else { return false }
        let startA = UInt(bitPattern: x), startB = UInt(bitPattern: y)
        let (endA, overflowA) = startA.addingReportingOverflow(UInt(a.count))
        let (endB, overflowB) = startB.addingReportingOverflow(UInt(b.count))
        return overflowA || overflowB || (startA < endB && startB < endA)
    }
}
