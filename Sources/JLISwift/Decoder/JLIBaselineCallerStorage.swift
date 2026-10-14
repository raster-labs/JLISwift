// SPDX-License-Identifier: Apache-2.0
extension JLIDecoder {
    public func inspectBaselineRGB(_ encoded: UnsafeRawBufferPointer, headerWorkspace: UnsafeMutableRawBufferPointer, configuration: JLIDecoderConfiguration = .default) throws -> BaselineRGBInfo {
        try jliCompatibility { inspectBaselineRGBCore(encoded, headerWorkspace: headerWorkspace, configuration: configuration, cancellation: .task) }
    }
    public func decodeBaselineRGB(_ encoded: UnsafeRawBufferPointer, arena: UnsafeMutableRawBufferPointer, workspace: UnsafeMutableRawBufferPointer, configuration: JLIDecoderConfiguration = .default) throws -> BaselineRGBInfo {
        try jliCompatibility { decodeBaselineRGBCore(encoded, arena: arena, workspace: workspace, configuration: configuration, cancellation: .task) }
    }

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
    public func inspectBaselineRGBCore(_ encoded: UnsafeRawBufferPointer,
        headerWorkspace: UnsafeMutableRawBufferPointer,
        configuration: JLIDecoderConfiguration = .default, cancellation: JLICancellation = .never) -> JLICoreOutcome<BaselineRGBInfo> {
        if case .failure(let failure) = baselineSpans(encoded, workspace: headerWorkspace, configuration: configuration, cancellation: cancellation) { return .failure(failure) }
        let storage = JLIBaselineParseStorage(workspace: headerWorkspace)
        defer { storage.records.destroy() }
        var parser = MarkerReader(borrowing: encoded, storage: .baseline(storage), cancellation: cancellation)
        let parsed: ParsedJPEG
        switch parser.parseCore() {
        case .success(let value): parsed = value
        case .failure(let failure): return .failure(failure)
        }
        return baselinePlan(parsed, storage: storage, configuration: configuration, cancellation: cancellation)
    }

    /// Decode sequential RGB with one MCU-row coefficient strip and bounded IDCT
    /// scratch. Three Float[N] slots retain exact component values, expand in
    /// place, then compact forward to RGB8. No final output copy is performed.
    ///
    /// All spans must be disjoint, exclusively borrowed and remain alive until
    /// return. Arena/workspace require Int alignment and trivial raw storage; their
    /// binding changes. On any error, partially written output must not be used.
    /// Metadata payloads are not returned. This API supports full-resolution RGB8.
    /// Header workspace includes concrete parser records and mutable control state.
    /// Failure values are scalar; compatibility error descriptions are constructed
    /// only by the original throwing APIs. External numerical calls require their
    /// own allocation qualification in addition to these supplied capacities.
    public func decodeBaselineRGBCore(_ encoded: UnsafeRawBufferPointer,
        arena: UnsafeMutableRawBufferPointer, workspace: UnsafeMutableRawBufferPointer,
        configuration: JLIDecoderConfiguration = .default, cancellation: JLICancellation = .never) -> JLICoreOutcome<BaselineRGBInfo> {
        if case .failure(let failure) = baselineSpans(encoded, workspace: workspace, configuration: configuration, cancellation: cancellation) { return .failure(failure) }
        guard let base = arena.baseAddress, UInt(bitPattern: base) % UInt(MemoryLayout<Int>.alignment) == 0,
              !Self.callerSpansOverlap(encoded, UnsafeRawBufferPointer(arena)),
              !Self.callerSpansOverlap(UnsafeRawBufferPointer(workspace), UnsafeRawBufferPointer(arena)) else {
            return .failure(JLICoreFailure(code: 153, kind: .decoding))
        }
        let storage = JLIBaselineParseStorage(workspace: workspace)
        defer { storage.records.destroy() }
        var parser = MarkerReader(borrowing: encoded, storage: .baseline(storage), cancellation: cancellation)
        let parsed: ParsedJPEG
        switch parser.parseCore() {
        case .success(let value): parsed = value
        case .failure(let failure): return .failure(failure)
        }
        let coreOutcome2 = baselinePlan(parsed, storage: storage, configuration: configuration, cancellation: cancellation)
        guard case .success(let info) = coreOutcome2 else { return .failure(coreOutcome2.failureValue) }
        guard arena.count >= info.arenaByteCount, workspace.count >= info.workspaceByteCount else {
            return .failure(JLICoreFailure(code: 154, kind: .decoding))
        }
        let reconstructionTables = storage.initializeReconstructionTables()
        let frame = parsed.frameInfo, n = frame.width * frame.height
        let hm = max(frame.components[0].horizontalSampling, frame.components[1].horizontalSampling, frame.components[2].horizontalSampling)
        let vm = max(frame.components[0].verticalSampling, frame.components[1].verticalSampling, frame.components[2].verticalSampling)
        let columns = (frame.width + 8 * hm - 1) / (8 * hm)
        let rows = (frame.height + 8 * vm - 1) / (8 * vm)
        let stripBlocks = JLITriple { columns * frame.components[$0].horizontalSampling * frame.components[$0].verticalSampling }
        let maxBlocks = stripBlocks.max() ?? 0
        let totalBlocks = stripBlocks.reduce(0, +)
        let compWidths = JLITriple { (frame.width * frame.components[$0].horizontalSampling + hm - 1) / hm }
        let compHeights = JLITriple { (frame.height * frame.components[$0].verticalSampling + vm - 1) / vm }
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
        for scanIndex in 0..<parsed.scans.count {
            let scan = parsed.scans[scanIndex]
            let tables = storage.huffmanViews
            for component in 0..<3 {
                let selector = scan.header.components.first { $0.componentSelector == frame.components[component].id }
                for tableKind in 0..<2 {
                    let isDC = tableKind == 0
                    let descriptor = storage.descriptor(scan: scanIndex, component: component, isDC: isDC)
                    let id = isDC ? (selector?.dcTableId ?? 0) : (selector?.acTableId ?? 0)
                    let fallback = isDC ? (id == 1 ? StandardHuffmanTables.dcChrominanceDefinition : StandardHuffmanTables.dcLuminanceDefinition) :
                        (id == 1 ? StandardHuffmanTables.acChrominanceDefinition : StandardHuffmanTables.acLuminanceDefinition)
                    let tableIndex = component * 2 + tableKind
                    let start = tableIndex * BorrowedHuffmanTable.byteCount
                    tables[tableIndex] = BorrowedHuffmanTable(workspace: UnsafeMutableRawBufferPointer(rebasing: tableBytes[start..<(start + BorrowedHuffmanTable.byteCount)]),
                        valueCount: descriptor.count >= 0 ? descriptor.count : fallback.count,
                        bits: { descriptor.count >= 0 ? encoded[descriptor.bits + $0] : fallback.bit($0) },
                        value: { descriptor.count >= 0 ? encoded[descriptor.values + $0] : fallback.value($0) })
                }
            }
            var components = JLITriple { _ in 0 }
            for index in 0..<scan.header.components.count {
                let selector = scan.header.components[index]
                guard let component = frame.components.firstIndex(where: { $0.id == selector.componentSelector }) else {
                    return .failure(JLICoreFailure(code: 155, kind: .decoding))
                }
                components[index] = component
            }
            let componentCount = scan.header.components.count
            let interleaved = componentCount > 1
            let first = components[0]
            let scanColumns = interleaved ? columns : (compWidths[first] + 7) / 8
            let scanRows = interleaved ? rows : (compHeights[first] + 7) / 8
            var reader = BitReader(borrowing: UnsafeRawBufferPointer(rebasing: encoded[storage.entropy(scanIndex)]))
            var previousDC = JLITriple { _ in Int32(0) }
            var mcu = 0, restart = 0
            let interval = storage.restartInterval(scanIndex)
            for row in 0..<scanRows {
                if case .failure(let failure) = cancellation.check() { return .failure(failure) }
                for column in 0..<scanColumns {
                    if interval > 0, mcu > 0, mcu % interval == 0 {
                        if case .failure(let failure) = reader.skipRestartMarkerCore(expectedIndex: restart) { return .failure(failure) }
                        restart = (restart + 1) & 7
                        for componentIndex in 0..<componentCount {
                            let component = components[componentIndex]
                            previousDC[component] = 0
                        }
                    }
                    mcu += 1
                    for componentIndex in 0..<componentCount {
                    let component = components[componentIndex]
                        let spec = frame.components[component]
                        let bh = interleaved ? spec.horizontalSampling : 1
                        let bv = interleaved ? spec.verticalSampling : 1
                        let blocksWide = scanColumns * bh
                        let componentOffset = stripBlocks.prefix(component).reduce(0, +) * 64
                        for by in 0..<bv { for bx in 0..<bh {
                            let offset = componentOffset + (by * blocksWide + column * bh + bx) * 64
                            let block = UnsafeMutableBufferPointer(rebasing: coefficients[offset..<(offset + 64)])
                            let coreOutcome3 = HuffmanDecoder.decodeDCCore(from: &reader, table: tables[component * 2])
                            guard case .success(let diff) = coreOutcome3 else { return .failure(coreOutcome3.failureValue) }
                            let (dc, overflow) = previousDC[component].addingReportingOverflow(diff)
                            guard !overflow else { return .failure(JLICoreFailure(code: 156, kind: .decoding)) }
                            previousDC[component] = dc
                            if case .failure(let failure) = HuffmanDecoder.decodeACCore(from: &reader, table: tables[component * 2 + 1], into: block) { return .failure(failure) }
                            block[0] = previousDC[component]
                        } }
                    }
                }
                for componentIndex in 0..<componentCount {
                    let component = components[componentIndex]
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
            (configuration.sourceColorModel == nil && (storage.adobeTransform == 0 || frame.components[0].id == 82 && frame.components[1].id == 71 && frame.components[2].id == 66)))
        for component in 0..<3 {
            let spec = frame.components[component]
            if case .failure(let failure) = ChromaSampling.upsampleInPlaceCore(UnsafeMutableBufferPointer(rebasing: planes[(component * n)..<((component + 1) * n)]),
                width: compWidths[component], height: compHeights[component], targetWidth: frame.width, targetHeight: frame.height,
                horizontalSampling: spec.horizontalSampling, verticalSampling: spec.verticalSampling,
                maximumHorizontalSampling: hm, maximumVerticalSampling: vm, centered: !xyb && !rgb && component != 0,
                rowScratch: rowCache, cancellation: cancellation) { return .failure(failure) }
        }
        for start in stride(from: 0, to: n, by: Self.conversionTilePixels) {
            if case .failure(let failure) = cancellation.check() { return .failure(failure) }
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
        return .success(info)
    }

    private func baselinePlan(_ parsed: ParsedJPEG, storage: JLIBaselineParseStorage,
                              configuration: JLIDecoderConfiguration, cancellation: JLICancellation) -> JLICoreOutcome<BaselineRGBInfo> {
        let frame = parsed.frameInfo
        if case .failure(let failure) = validateDecodableCore(frame, quantTableCount: 4) { return .failure(failure) }
        if case .failure(let failure) = storage.validateCoverage() { return .failure(failure) }
        guard !frame.isLossless, !frame.isProgressive, frame.precision == 8, frame.components.count == 3,
              configuration.scale == 1, configuration.outputPixelFormat == nil || configuration.outputPixelFormat == .uint8,
              configuration.outputColorModel == nil || configuration.outputColorModel == .rgb else {
            return .failure(JLICoreFailure(code: 157, kind: .unsupported))
        }
        let (n, overflow) = frame.width.multipliedReportingOverflow(by: frame.height)
        let (arenaBytes, arenaOverflow) = n.multipliedReportingOverflow(by: 12)
        let (outputBytes, outputOverflow) = n.multipliedReportingOverflow(by: 3)
        guard !overflow, !arenaOverflow, !outputOverflow, n <= configuration.maximumPixels,
              outputBytes <= configuration.maximumDecodedBytes else { return .failure(JLICoreFailure(code: 158, kind: .decoding)) }
        let hm = max(frame.components[0].horizontalSampling, frame.components[1].horizontalSampling, frame.components[2].horizontalSampling)
        let columns = (frame.width + 8 * hm - 1) / (8 * hm)
        let blocks = JLITriple { columns * frame.components[$0].horizontalSampling * frame.components[$0].verticalSampling }
        let workspaceBytes = Self.baselineHeaderWorkspaceByteCount + 6 * BorrowedHuffmanTable.byteCount + 3 * 64 * 4 +
            blocks.reduce(0, +) * 256 + (blocks.max() ?? 0) * 512 + frame.width * 12 + Self.conversionTilePixels * 35
        return .success(BaselineRGBInfo(width: frame.width, height: frame.height, outputByteCount: outputBytes,
            arenaByteCount: arenaBytes, workspaceByteCount: workspaceBytes))
    }
    private func baselineSpans(_ encoded: UnsafeRawBufferPointer, workspace: UnsafeMutableRawBufferPointer,
                               configuration: JLIDecoderConfiguration, cancellation: JLICancellation) -> JLICoreOutcome<Void> {
        guard encoded.count <= configuration.maximumEncodedBytes, workspace.count >= Self.baselineHeaderWorkspaceByteCount,
              let address = workspace.baseAddress, UInt(bitPattern: address) % UInt(MemoryLayout<Int>.alignment) == 0,
              !Self.callerSpansOverlap(encoded, UnsafeRawBufferPointer(workspace)) else {
            return .failure(JLICoreFailure(code: 159, kind: .decoding))
        }
        if let source = configuration.sourceColorModel, source != .rgb && source != .yCbCr {
            return .failure(JLICoreFailure(code: 160, kind: .unsupported))
        }
        if case .failure(let failure) = cancellation.check() { return .failure(failure) }
        return .success(())
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
