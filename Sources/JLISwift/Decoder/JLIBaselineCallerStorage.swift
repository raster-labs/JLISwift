// SPDX-License-Identifier: Apache-2.0
import Accelerate

extension JLIDecoder {
    /// RGB8 result layout. The output occupies the first outputByteCount bytes of
    /// the arena; callers must retain and charge its full arenaByteCount capacity.
    public struct BaselineRGBInfo: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let outputByteCount: Int
        public let arenaByteCount: Int
        public let workspaceByteCount: Int
    }
    public static var baselineHeaderWorkspaceByteCount: Int { JLIBaselineParseStorage.byteCount }
    private static let conversionTilePixels = 1024

    /// Inspect the complete sequential RGB structure with borrowed payload spans.
    public func inspectBaselineRGB(_ encoded: UnsafeRawBufferPointer,
        headerWorkspace: UnsafeMutableRawBufferPointer,
        configuration: JLIDecoderConfiguration = .default) throws -> BaselineRGBInfo {
        try baselineSpans(encoded, workspace: headerWorkspace, configuration: configuration)
        let storage = JLIBaselineParseStorage(workspace: headerWorkspace)
        var parser = MarkerReader(borrowing: encoded, storage: storage)
        return try baselinePlan(parser.parse(), storage: storage, configuration: configuration)
    }

    /// Decode sequential RGB with one MCU-row coefficient strip and bounded IDCT
    /// scratch. Three Float[N] slots retain exact component values, expand in
    /// place, then compact forward to RGB8. No final output copy is performed.
    ///
    /// All spans must be disjoint, exclusively borrowed and remain alive until
    /// return. Arena/workspace require Int alignment and trivial raw storage; their
    /// binding changes. On any error, partially written output must not be used.
    /// Metadata payloads are not returned. This API supports full-resolution RGB8.
    /// Reported capacities cover payload storage, not Swift runtime/control objects.
    public func decodeBaselineRGB(_ encoded: UnsafeRawBufferPointer,
        arena: UnsafeMutableRawBufferPointer, workspace: UnsafeMutableRawBufferPointer,
        configuration: JLIDecoderConfiguration = .default) throws -> BaselineRGBInfo {
        try baselineSpans(encoded, workspace: workspace, configuration: configuration)
        guard let base = arena.baseAddress, UInt(bitPattern: base) % UInt(MemoryLayout<Int>.alignment) == 0,
              !Self.callerSpansOverlap(encoded, UnsafeRawBufferPointer(arena)),
              !Self.callerSpansOverlap(UnsafeRawBufferPointer(workspace), UnsafeRawBufferPointer(arena)) else {
            throw JLIError.decodingFailed("Invalid RGB arena alignment or overlapping spans")
        }
        let storage = JLIBaselineParseStorage(workspace: workspace)
        var parser = MarkerReader(borrowing: encoded, storage: storage)
        let parsed = try parser.parse()
        let info = try baselinePlan(parsed, storage: storage, configuration: configuration)
        guard arena.count >= info.arenaByteCount, workspace.count >= info.workspaceByteCount else {
            throw JLIError.decodingFailed("Insufficient RGB arena/workspace capacity")
        }
        let reconstructionTables = storage.initializeReconstructionTables()
        let frame = parsed.frameInfo, n = frame.width * frame.height
        let hm = frame.components.map(\.horizontalSampling).max() ?? 1
        let vm = frame.components.map(\.verticalSampling).max() ?? 1
        let columns = (frame.width + 8 * hm - 1) / (8 * hm)
        let rows = (frame.height + 8 * vm - 1) / (8 * vm)
        let stripBlocks = frame.components.map { columns * $0.horizontalSampling * $0.verticalSampling }
        let maxBlocks = stripBlocks.max() ?? 0
        let totalBlocks = stripBlocks.reduce(0, +)
        let compWidths = frame.components.map { (frame.width * $0.horizontalSampling + hm - 1) / hm }
        let compHeights = frame.components.map { (frame.height * $0.verticalSampling + vm - 1) / vm }
        var cursor = JLICallerWorkspace(bytes: workspace, offset: Self.baselineHeaderWorkspaceByteCount)
        let tableBytes = cursor.raw(6 * BorrowedHuffmanTable.byteCount)
        let quant = cursor.buffer(Float.self, 3 * 64)
        let coefficients = cursor.buffer(Int32.self, totalBlocks * 64)
        let pixels = cursor.buffer(Float.self, maxBlocks * 64)
        let idct = cursor.buffer(Float.self, maxBlocks * 64)
        let rowCache = cursor.buffer(Float.self, frame.width * 3)
        let tileFloats = cursor.buffer(Float.self, Self.conversionTilePixels * 8)
        let tileBytes = cursor.buffer(UInt8.self, Self.conversionTilePixels * 3)
        let planes = UnsafeMutableRawBufferPointer(rebasing: arena[..<info.arenaByteCount]).bindMemory(to: Float.self)
        for component in 0..<3 {
            for zigzag in 0..<64 {
                quant[component * 64 + reconstructionTables.zigzag[zigzag]] = storage.quantizationValue(
                    component: component, zigzag: zigzag, input: encoded)
            }
        }
        for (scanIndex, scan) in parsed.scans.enumerated() {
            var tables = [BorrowedHuffmanTable]()
            tables.reserveCapacity(6)
            for component in 0..<3 {
                let selector = scan.header.components.first { $0.componentSelector == frame.components[component].id }
                for isDC in [true, false] {
                    let descriptor = storage.descriptor(scan: scanIndex, component: component, isDC: isDC)
                    let id = isDC ? (selector?.dcTableId ?? 0) : (selector?.acTableId ?? 0)
                    let fallback = isDC ? (id == 1 ? StandardHuffmanTables.dcChrominanceDefinition : StandardHuffmanTables.dcLuminanceDefinition) :
                        (id == 1 ? StandardHuffmanTables.acChrominanceDefinition : StandardHuffmanTables.acLuminanceDefinition)
                    let start = tables.count * BorrowedHuffmanTable.byteCount
                    tables.append(BorrowedHuffmanTable(workspace: UnsafeMutableRawBufferPointer(rebasing: tableBytes[start..<(start + BorrowedHuffmanTable.byteCount)]),
                        valueCount: descriptor.count >= 0 ? descriptor.count : fallback.count,
                        bits: { descriptor.count >= 0 ? encoded[descriptor.bits + $0] : fallback.bit($0) },
                        value: { descriptor.count >= 0 ? encoded[descriptor.values + $0] : fallback.value($0) }))
                }
            }
            let components = try scan.header.components.map { selector -> Int in
                guard let index = frame.components.firstIndex(where: { $0.id == selector.componentSelector }) else {
                    throw JLIError.decodingFailed("Unknown scan component")
                }
                return index
            }
            let interleaved = components.count > 1
            let first = components[0]
            let scanColumns = interleaved ? columns : (compWidths[first] + 7) / 8
            let scanRows = interleaved ? rows : (compHeights[first] + 7) / 8
            var reader = BitReader(borrowing: UnsafeRawBufferPointer(rebasing: encoded[storage.entropy(scanIndex)]))
            var previousDC: [Int32] = [0, 0, 0]
            var mcu = 0, restart = 0
            let interval = storage.restartInterval(scanIndex)
            for row in 0..<scanRows {
                try Task.checkCancellation()
                for column in 0..<scanColumns {
                    if interval > 0, mcu > 0, mcu % interval == 0 {
                        try reader.skipRestartMarker(expectedIndex: restart)
                        restart = (restart + 1) & 7
                        for component in components { previousDC[component] = 0 }
                    }
                    mcu += 1
                    for component in components {
                        let spec = frame.components[component]
                        let bh = interleaved ? spec.horizontalSampling : 1
                        let bv = interleaved ? spec.verticalSampling : 1
                        let blocksWide = scanColumns * bh
                        let componentOffset = stripBlocks.prefix(component).reduce(0, +) * 64
                        for by in 0..<bv { for bx in 0..<bh {
                            let offset = componentOffset + (by * blocksWide + column * bh + bx) * 64
                            let block = UnsafeMutableBufferPointer(rebasing: coefficients[offset..<(offset + 64)])
                            let diff = try HuffmanDecoder.decodeDC(from: &reader, table: tables[component * 2])
                            let (dc, overflow) = previousDC[component].addingReportingOverflow(diff)
                            guard !overflow else { throw JLIError.decodingFailed("DC coefficient overflow") }
                            previousDC[component] = dc
                            try HuffmanDecoder.decodeAC(from: &reader, table: tables[component * 2 + 1], into: block)
                            block[0] = previousDC[component]
                        } }
                    }
                }
                for component in components {
                    let spec = frame.components[component]
                    let bh = interleaved ? spec.horizontalSampling : 1
                    let bv = interleaved ? spec.verticalSampling : 1
                    let blockCount = scanColumns * bh * bv
                    let componentOffset = stripBlocks.prefix(component).reduce(0, +) * 64
                    guard let zz = coefficients.baseAddress, let qt = quant.baseAddress,
                          let px = pixels.baseAddress, let scratch = idct.baseAddress, let plane = planes.baseAddress else {
                        preconditionFailure("Validated workspace has no backing")
                    }
                    Self.reconstructBlocks(0..<blockCount,
                        ptrs: ReconstructPtrs(zz: zz + componentOffset, qt: qt + component * 64,
                            px: px, scratch: scratch, plane: plane + component * n),
                        blocksH: scanColumns * bh, compWidth: compWidths[component], compHeight: compHeights[component],
                        precision: 8, firstBlockRow: row * bv, tables: reconstructionTables)
                }
            }
        }
        let xyb = storage.isXYB(input: encoded)
        let rgb = !xyb && (configuration.sourceColorModel == .rgb ||
            (configuration.sourceColorModel == nil && (storage.adobeTransform == 0 || frame.components.map(\.id) == [82, 71, 66])))
        for component in 0..<3 {
            let spec = frame.components[component]
            try ChromaSampling.upsampleInPlace(UnsafeMutableBufferPointer(rebasing: planes[(component * n)..<((component + 1) * n)]),
                width: compWidths[component], height: compHeights[component], targetWidth: frame.width, targetHeight: frame.height,
                horizontalSampling: spec.horizontalSampling, verticalSampling: spec.verticalSampling,
                maximumHorizontalSampling: hm, maximumVerticalSampling: vm, centered: !xyb && !rgb && component != 0,
                rowScratch: rowCache)
        }
        for start in stride(from: 0, to: n, by: Self.conversionTilePixels) {
            try Task.checkCancellation()
            let count = min(Self.conversionTilePixels, n - start)
            for component in 0..<3 { for pixel in 0..<count {
                let sample = planes[component * n + start + pixel]
                tileFloats[component * count + pixel] = component == 0 && !xyb && !rgb ? sample.rounded() : sample
            } }
            if xyb || rgb {
                for pixel in 0..<count {
                    let a = tileFloats[pixel], b = tileFloats[count + pixel], c = tileFloats[2 * count + pixel]
                    let values = xyb ? ColorConversion.xybSampleToRGB(x: a, y: b, bChannel: c) : (a, b, c)
                    arena[(start + pixel) * 3] = UInt8(clamping: Int(values.0.rounded()))
                    arena[(start + pixel) * 3 + 1] = UInt8(clamping: Int(values.1.rounded()))
                    arena[(start + pixel) * 3 + 2] = UInt8(clamping: Int(values.2.rounded()))
                }
            } else {
                guard let input = tileFloats.baseAddress, let bytePlanes = tileBytes.baseAddress else { preconditionFailure() }
                AccelerateDSP.imageYCbCrToRGB(y: input, cb: input + count, cr: input + count * 2,
                    pixelCount: count, scratch: input + count * 3, planes: bytePlanes, output: base + start * 3)
            }
        }
        return info
    }

    private func baselinePlan(_ parsed: ParsedJPEG, storage: JLIBaselineParseStorage,
                              configuration: JLIDecoderConfiguration) throws -> BaselineRGBInfo {
        let frame = parsed.frameInfo
        try validateDecodable(frame, quantTableCount: 4)
        try storage.validateCoverage()
        guard !frame.isLossless, !frame.isProgressive, frame.precision == 8, frame.components.count == 3,
              configuration.scale == 1, configuration.outputPixelFormat == nil || configuration.outputPixelFormat == .uint8,
              configuration.outputColorModel == nil || configuration.outputColorModel == .rgb else {
            throw JLIError.unsupportedJPEGFeature("Caller-storage sequential decoding requires full-resolution RGB8")
        }
        let (n, overflow) = frame.width.multipliedReportingOverflow(by: frame.height)
        let (arenaBytes, arenaOverflow) = n.multipliedReportingOverflow(by: 12)
        let (outputBytes, outputOverflow) = n.multipliedReportingOverflow(by: 3)
        guard !overflow, !arenaOverflow, !outputOverflow, n <= configuration.maximumPixels,
              outputBytes <= configuration.maximumDecodedBytes else { throw JLIError.decodingFailed("RGB size exceeds limits") }
        let hm = frame.components.map(\.horizontalSampling).max() ?? 1
        let columns = (frame.width + 8 * hm - 1) / (8 * hm)
        let blocks = frame.components.map { columns * $0.horizontalSampling * $0.verticalSampling }
        let workspaceBytes = Self.baselineHeaderWorkspaceByteCount + 6 * BorrowedHuffmanTable.byteCount + 3 * 64 * 4 +
            blocks.reduce(0, +) * 256 + (blocks.max() ?? 0) * 512 + frame.width * 12 + Self.conversionTilePixels * 35
        return BaselineRGBInfo(width: frame.width, height: frame.height, outputByteCount: outputBytes,
            arenaByteCount: arenaBytes, workspaceByteCount: workspaceBytes)
    }
    private func baselineSpans(_ encoded: UnsafeRawBufferPointer, workspace: UnsafeMutableRawBufferPointer,
                               configuration: JLIDecoderConfiguration) throws {
        guard encoded.count <= configuration.maximumEncodedBytes, workspace.count >= Self.baselineHeaderWorkspaceByteCount,
              let address = workspace.baseAddress, UInt(bitPattern: address) % UInt(MemoryLayout<Int>.alignment) == 0,
              !Self.callerSpansOverlap(encoded, UnsafeRawBufferPointer(workspace)) else {
            throw JLIError.decodingFailed("Invalid RGB input/header workspace")
        }
        if let source = configuration.sourceColorModel, source != .rgb && source != .yCbCr {
            throw JLIError.unsupportedJPEGFeature("Unsupported JPEG source color interpretation")
        }
        try Task.checkCancellation()
    }
}

private struct JLICallerWorkspace {
    let bytes: UnsafeMutableRawBufferPointer
    var offset: Int
    mutating func raw(_ count: Int) -> UnsafeMutableRawBufferPointer {
        precondition(count >= 0 && count <= bytes.count - offset)
        defer { offset += count }
        return UnsafeMutableRawBufferPointer(rebasing: bytes[offset..<(offset + count)])
    }
    mutating func buffer<T>(_ type: T.Type, _ count: Int) -> UnsafeMutableBufferPointer<T> {
        raw(count * MemoryLayout<T>.stride).bindMemory(to: T.self)
    }
}
