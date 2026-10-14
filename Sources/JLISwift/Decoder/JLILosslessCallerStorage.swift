// SPDX-License-Identifier: Apache-2.0
extension JLIDecoder {
    public func inspectLosslessMonochrome(_ encoded: UnsafeRawBufferPointer, workspace: UnsafeMutableRawBufferPointer, configuration: JLIDecoderConfiguration = .default) throws -> LosslessMonochromeInfo {
        try jliCompatibility { inspectLosslessMonochromeCore(encoded, workspace: workspace, configuration: configuration, cancellation: .task) }
    }
    public func decodeLosslessMonochrome(_ encoded: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer, workspace: UnsafeMutableRawBufferPointer, configuration: JLIDecoderConfiguration = .default) throws -> LosslessMonochromeInfo {
        try jliCompatibility { decodeLosslessMonochromeCore(encoded, into: output, workspace: workspace, configuration: configuration, cancellation: .task) }
    }

    /// Scalar description of the pixel-only caller-storage lossless result.
    public struct LosslessMonochromeInfo: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let precision: Int
        public let pointTransform: Int
        /// Caller storage always contains unsigned, little-endian 16-bit samples.
        public var outputByteCount: Int { width * height * 2 }
    }

    /// Fixed raw storage for parser records, mutable control state, descriptors,
    /// and the decode-only Huffman table. The caller supplies exclusive,
    /// Int-aligned raw storage and retains it until the synchronous call returns.
    /// Compatibility error descriptions are outside the core storage contract.
    public static var losslessMonochromeWorkspaceByteCount: Int {
        JLILosslessParseStorage.headerByteCount + BorrowedHuffmanTable.byteCount
    }

    /// Fully parses a monochrome SOF3 stream with the canonical marker parser,
    /// borrowing encoded table and entropy spans. No metadata payload is returned.
    public func inspectLosslessMonochromeCore(_ encoded: UnsafeRawBufferPointer,
        workspace: UnsafeMutableRawBufferPointer,
        configuration: JLIDecoderConfiguration = .default, cancellation: JLICancellation = .never) -> JLICoreOutcome<LosslessMonochromeInfo> {
        if case .failure(let failure) = callerSpans(encoded, workspace: workspace, configuration: configuration, cancellation: cancellation) { return .failure(failure) }
        let storage = losslessStorage(workspace)
        defer { storage.records.destroy() }
        var parser = MarkerReader(borrowing: encoded, storage: .lossless(storage), cancellation: cancellation)
        let parsed: ParsedJPEG
        switch parser.parseCore() {
        case .success(let value): parsed = value
        case .failure(let failure): return .failure(failure)
        }
        return losslessMonochromePlan(parsed, configuration: configuration, cancellation: cancellation)
    }

    /// Reconstructs directly in supplied little-endian UInt16 output using the
    /// existing prediction/Huffman kernel. All spans must be disjoint and remain
    /// alive for this synchronous call. Output must not be published on failure;
    /// cancellation or malformed entropy may leave partially written samples.
    /// Input/entropy/metadata and full-frame intermediate copies are avoided.
    public func decodeLosslessMonochromeCore(_ encoded: UnsafeRawBufferPointer,
        into output: UnsafeMutableRawBufferPointer, workspace: UnsafeMutableRawBufferPointer,
        configuration: JLIDecoderConfiguration = .default, cancellation: JLICancellation = .never) -> JLICoreOutcome<LosslessMonochromeInfo> {
        if case .failure(let failure) = callerSpans(encoded, workspace: workspace, configuration: configuration, cancellation: cancellation) { return .failure(failure) }
        guard !Self.callerSpansOverlap(encoded, UnsafeRawBufferPointer(output)),
              !Self.callerSpansOverlap(UnsafeRawBufferPointer(workspace), UnsafeRawBufferPointer(output)) else {
            return .failure(JLICoreFailure(code: 161, kind: .decoding))
        }
        let storage = losslessStorage(workspace)
        defer { storage.records.destroy() }
        var parser = MarkerReader(borrowing: encoded, storage: .lossless(storage), cancellation: cancellation)
        let parsed: ParsedJPEG
        switch parser.parseCore() {
        case .success(let value): parsed = value
        case .failure(let failure): return .failure(failure)
        }
        let coreOutcome2 = losslessMonochromePlan(parsed, configuration: configuration, cancellation: cancellation)
        guard case .success(let info) = coreOutcome2 else { return .failure(coreOutcome2.failureValue) }
        guard output.count >= info.outputByteCount else {
            return .failure(JLICoreFailure(code: 162, kind: .decoding))
        }
        let coreOutcome3 = Self.losslessParametersCore(frame: parsed.frameInfo, scans: parsed.scans, configuration: configuration)
        guard case .success(let plan) = coreOutcome3 else { return .failure(coreOutcome3.failureValue) }
        let tableOffset = JLILosslessParseStorage.headerByteCount
        let tableWorkspace = UnsafeMutableRawBufferPointer(rebasing: workspace[tableOffset..<Self.losslessMonochromeWorkspaceByteCount])
        let descriptor = storage.selected
        let fallback = storage.selectedID == 1 ? StandardHuffmanTables.dcChrominanceDefinition : StandardHuffmanTables.dcLuminanceDefinition
        let table = BorrowedHuffmanTable(workspace: tableWorkspace,
            valueCount: descriptor.count >= 0 ? descriptor.count : fallback.count,
            bits: { descriptor.count >= 0 ? encoded[descriptor.bits + $0] : fallback.bit($0) },
            value: { descriptor.count >= 0 ? encoded[descriptor.values + $0] : fallback.value($0) })
        var reader = BitReader(borrowing: UnsafeRawBufferPointer(rebasing: encoded[storage.entropy]))
        let w = info.width, h = info.height
        // DRI applies to subsequent scans; a marker after this SOS/entropy span
        // must not retroactively change the restart topology being decoded.
        let interval = storage.restartInterval
        guard interval == 0 || interval % w == 0 else {
            return .failure(JLICoreFailure(code: 163, kind: .unsupported))
        }
        let rowsPerRegion = interval > 0 ? interval / w : h
        let regions = 1 + (h - 1) / rowsPerRegion
        let half = Int32(1 << (info.precision - 1 - info.pointTransform))
        for region in 0..<regions {
            if case .failure(let failure) = cancellation.check() { return .failure(failure) }
            if region > 0 { if case .failure(let failure) = reader.skipRestartMarkerCore(expectedIndex: (region - 1) & 7) { return .failure(failure) } }
            let row = region * rowsPerRegion
            let rows = min(rowsPerRegion, h - row)
            let start = row * w * 2, end = start + rows * w * 2
            let plane = LosslessLittleEndianSamples(bytes: UnsafeMutableRawBufferPointer(rebasing: output[start..<end]))
            if case .failure(let failure) = Self.losslessScanGrayIntoCore(plane, width: w, height: rows, predictor: plan.predictor,
                half: half, table: table, reader: &reader, cancellation: cancellation) { return .failure(failure) }
        }
        let samples = LosslessLittleEndianSamples(bytes: output)
        for index in 0..<(w * h) {
            if index & 0xFFFF == 0 { if case .failure(let failure) = cancellation.check() { return .failure(failure) } }
            // Match existing output serialization, including <=8-bit clamp.
            let shifted = Int(samples[index]) << info.pointTransform
            samples[index] = Int32(info.precision <= 8 ? Int(UInt8(clamping: shifted)) : Int(UInt16(clamping: shifted)))
        }
        return .success(info)
    }

    private func losslessMonochromePlan(_ parsed: ParsedJPEG,
        configuration: JLIDecoderConfiguration, cancellation: JLICancellation) -> JLICoreOutcome<LosslessMonochromeInfo> {
        let frame = parsed.frameInfo
        guard frame.isLossless, frame.components.count == 1 else {
            return .failure(JLICoreFailure(code: 164, kind: .unsupported))
        }
        guard configuration.outputPixelFormat == nil || configuration.outputPixelFormat == .uint16 else {
            return .failure(JLICoreFailure(code: 165, kind: .unsupported))
        }
        let coreOutcome1 = Self.losslessParametersCore(frame: frame, scans: parsed.scans, configuration: configuration)
        guard case .success(let plan) = coreOutcome1 else { return .failure(coreOutcome1.failureValue) }
        let (pixels, overflow) = frame.width.multipliedReportingOverflow(by: frame.height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 2)
        guard !overflow, !byteOverflow, pixels <= configuration.maximumPixels,
              bytes <= configuration.maximumDecodedBytes else {
            return .failure(JLICoreFailure(code: 166, kind: .decoding))
        }
        guard configuration.outputColorModel == nil || configuration.outputColorModel == .grayscale else {
            return .failure(JLICoreFailure(code: 167, kind: .unsupported))
        }
        return .success(LosslessMonochromeInfo(width: frame.width, height: frame.height,
            precision: frame.precision, pointTransform: plan.pointTransform))
    }

    private func losslessStorage(_ workspace: UnsafeMutableRawBufferPointer) -> JLILosslessParseStorage {
        JLILosslessParseStorage(workspace: workspace)
    }

    private func callerSpans(_ encoded: UnsafeRawBufferPointer, workspace: UnsafeMutableRawBufferPointer,
                             configuration: JLIDecoderConfiguration, cancellation: JLICancellation) -> JLICoreOutcome<Void> {
        guard encoded.count <= configuration.maximumEncodedBytes,
              workspace.count >= Self.losslessMonochromeWorkspaceByteCount,
              let address = workspace.baseAddress,
              UInt(bitPattern: address) % UInt(MemoryLayout<Int>.alignment) == 0,
              !Self.callerSpansOverlap(encoded, UnsafeRawBufferPointer(workspace)) else {
            return .failure(JLICoreFailure(code: 168, kind: .decoding))
        }
        if let source = configuration.sourceColorModel, source != .rgb && source != .yCbCr {
            return .failure(JLICoreFailure(code: 169, kind: .unsupported))
        }
        if case .failure(let failure) = cancellation.check() { return .failure(failure) }
        return .success(())
    }

    internal static func callerSpansOverlap(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer) -> Bool {
        guard !a.isEmpty, !b.isEmpty, let x = a.baseAddress, let y = b.baseAddress else { return false }
        let startA = UInt(bitPattern: x), startB = UInt(bitPattern: y)
        let (endA, overflowA) = startA.addingReportingOverflow(UInt(a.count))
        let (endB, overflowB) = startB.addingReportingOverflow(UInt(b.count))
        return overflowA || overflowB || (startA < endB && startB < endA)
    }
}
