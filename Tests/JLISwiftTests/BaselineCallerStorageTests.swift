import Foundation
import Testing
@testable import JLISwift

@Suite("Caller-owned baseline RGB storage")
struct BaselineCallerStorageTests {
    @Test("Reconstruction constants fit the admitted header, preserve exact values and remain independent")
    func reconstructionTables() {
        let size = JLIDecoder.baselineHeaderWorkspaceByteCount
        let a = UnsafeMutableRawPointer.allocate(byteCount: size + 32, alignment: 16)
        let b = UnsafeMutableRawPointer.allocate(byteCount: size + 32, alignment: 16)
        defer { a.deallocate(); b.deallocate() }
        a.initializeMemory(as: UInt8.self, repeating: 0xAB, count: size + 32)
        b.initializeMemory(as: UInt8.self, repeating: 0xCD, count: size + 32)
        let first = JLIBaselineParseStorage(workspace: .init(start: a + 16, count: size))
        let second = JLIBaselineParseStorage(workspace: .init(start: b + 16, count: size))
        let t = first.initializeReconstructionTables(), u = second.initializeReconstructionTables()
        #expect(UnsafeRawPointer(t.dct) - UnsafeRawPointer(a + 16) == 5536)
        #expect(UnsafeRawPointer(t.transposedDCT) - UnsafeRawPointer(a + 16) == 5792)
        #expect(UnsafeRawPointer(t.zigzag) - UnsafeRawPointer(a + 16) == 6048)
        #expect(UnsafeRawPointer(t.inverseZigzag) - UnsafeRawPointer(a + 16) == 6560)
        for index in 0..<64 {
            #expect(t.dct[index].bitPattern == AccelerateDSP.dctMatrix[index].bitPattern)
            #expect(t.transposedDCT[index].bitPattern == AccelerateDSP.dctMatrixTransposed[index].bitPattern)
            #expect(t.zigzag[index] == Quantization.zigzagOrder[index])
            #expect(t.inverseZigzag[index] == Quantization.inverseZigzagOrder[index])
            #expect(t.inverseZigzag[t.zigzag[index]] == index)
            #expect(t.transposedDCT[(index % 8) * 8 + index / 8] == t.dct[index])
        }
        // Mutating one admitted span cannot change another decode or the owned tables.
        UnsafeMutablePointer(mutating: t.dct)[0] = -999
        UnsafeMutablePointer(mutating: t.zigzag)[0] = 63
        #expect(u.dct[0] == AccelerateDSP.dctMatrix[0])
        #expect(u.zigzag[0] == 0 && Quantization.zigzagOrder[0] == 0)
        for index in 0..<16 {
            #expect(a.load(fromByteOffset: index, as: UInt8.self) == 0xAB)
            #expect(b.load(fromByteOffset: index, as: UInt8.self) == 0xCD)
        }
        for offset in (16 + 12288)..<(size + 32) {
            #expect(a.load(fromByteOffset: offset, as: UInt8.self) == 0xAB)
            #expect(b.load(fromByteOffset: offset, as: UInt8.self) == 0xCD)
        }
    }

    private func decode(_ data: [UInt8], configuration: JLIDecoderConfiguration = .default) throws -> [UInt8] {
        try data.withUnsafeBytes { input in
            let header = UnsafeMutableRawPointer.allocate(byteCount: JLIDecoder.baselineHeaderWorkspaceByteCount, alignment: 16)
            defer { header.deallocate() }
            let info = try JLIDecoder().inspectBaselineRGB(input,
                headerWorkspace: UnsafeMutableRawBufferPointer(start: header, count: JLIDecoder.baselineHeaderWorkspaceByteCount), configuration: configuration)
            let arena = UnsafeMutableRawPointer.allocate(byteCount: info.arenaByteCount + 32, alignment: 16)
            let workspace = UnsafeMutableRawPointer.allocate(byteCount: info.workspaceByteCount + 32, alignment: 16)
            defer { arena.deallocate(); workspace.deallocate() }
            arena.initializeMemory(as: UInt8.self, repeating: 0xCD, count: info.arenaByteCount + 32)
            workspace.initializeMemory(as: UInt8.self, repeating: 0xAB, count: info.workspaceByteCount + 32)
            let actual = try JLIDecoder().decodeBaselineRGB(input,
                arena: UnsafeMutableRawBufferPointer(start: arena + 16, count: info.arenaByteCount),
                workspace: UnsafeMutableRawBufferPointer(start: workspace + 16, count: info.workspaceByteCount), configuration: configuration)
            #expect(actual == info)
            #expect(info.arenaByteCount == info.width * info.height * 12)
            for i in 0..<16 {
                #expect(arena.load(fromByteOffset: i, as: UInt8.self) == 0xCD)
                #expect(arena.load(fromByteOffset: info.arenaByteCount + 16 + i, as: UInt8.self) == 0xCD)
                #expect(workspace.load(fromByteOffset: i, as: UInt8.self) == 0xAB)
                #expect(workspace.load(fromByteOffset: info.workspaceByteCount + 16 + i, as: UInt8.self) == 0xAB)
            }
            return Array(UnsafeRawBufferPointer(start: arena + 16, count: info.outputByteCount))
        }
    }

    @Test("Strip reconstruction matches full-frame decoding across geometry, color and restarts",
          arguments: [1, 2, 3, 7, 8, 9, 17, 33, 65])
    func imageParity(width: Int) throws {
        for height in [1, 3, 9, 19] {
            let sampleCount = width * height * 3
            let bytes = (0..<sampleCount).map { (index: Int) -> UInt8 in
                let mixed = index * 39 + index / 7
                return UInt8(mixed & 255)
            }
            let image = try JLIImage(width: width, height: height, pixelFormat: .uint8, colorModel: .rgb, data: bytes)
            for sampling in [JLIChromaSubsampling.yuv444, .yuv422, .yuv420] {
                for restart in [0, 1, 3] {
                    var config = JLIEncoderConfiguration.default
                    config.chromaSubsampling = sampling; config.restartInterval = restart
                    config.adaptiveQuantization = false
                    let encoded = try JLIEncoder().encode(image, configuration: config)
                    #expect(try decode(encoded) == JLIDecoder().decode(from: encoded).data,
                            "Geometry \(width)x\(height), sampling \(sampling), restart \(restart)")
                    var rgb = JLIDecoderConfiguration.default; rgb.sourceColorModel = .rgb
                    #expect(try decode(encoded, configuration: rgb) == JLIDecoder().decode(from: encoded, configuration: rgb).data)
                }
            }
            var config = JLIEncoderConfiguration.default
            config.colorSpace = .xyb; config.adaptiveQuantization = false
            let encoded = try JLIEncoder().encode(image, configuration: config)
            #expect(try decode(encoded) == JLIDecoder().decode(from: encoded).data)
        }
    }

    @Test("Caller capacities and cancellation fail before publishing")
    func invalidCapacity() throws {
        let image = try JLIImage(width: 3, height: 2, pixelFormat: .uint8, colorModel: .rgb,
                                 data: Array(repeating: 128, count: 18))
        let encoded = try JLIEncoder().encode(image)
        try encoded.withUnsafeBytes { input in
            let header = UnsafeMutableRawPointer.allocate(byteCount: 16384, alignment: 16)
            defer { header.deallocate() }
            let head = UnsafeMutableRawBufferPointer(start: header, count: 16384)
            let info = try JLIDecoder().inspectBaselineRGB(input, headerWorkspace: head)
            let p = UnsafeMutableRawPointer.allocate(byteCount: info.workspaceByteCount, alignment: 16)
            let a = UnsafeMutableRawPointer.allocate(byteCount: info.arenaByteCount, alignment: 16)
            defer { p.deallocate(); a.deallocate() }
            let work = UnsafeMutableRawBufferPointer(start: p, count: info.workspaceByteCount)
            let arena = UnsafeMutableRawBufferPointer(start: a, count: info.arenaByteCount)
            #expect(throws: JLIError.self) { try JLIDecoder().decodeBaselineRGB(input, arena: arena, workspace: UnsafeMutableRawBufferPointer(rebasing: work.dropLast())) }
            #expect(throws: JLIError.self) { try JLIDecoder().decodeBaselineRGB(input, arena: UnsafeMutableRawBufferPointer(rebasing: arena.dropLast()), workspace: work) }
            #expect(throws: JLIError.self) { try JLIDecoder().decodeBaselineRGB(input, arena: work, workspace: work) }
            var limit = JLIDecoderConfiguration.default; limit.maximumDecodedBytes = 17
            #expect(throws: JLIError.self) { try JLIDecoder().inspectBaselineRGB(input, headerWorkspace: head, configuration: limit) }
        }
    }

    private func sequential(scans: [[Int]], intervals: [Int], redefineQuantization: Bool) -> [UInt8] {
        let width = 17, height = 19, columns = 3, rows = 3
        var data: [UInt8] = [0xff, 0xd8, 0xff, 0xc0, 0, 17, 8, 0, UInt8(height), 0, UInt8(width), 3,
                            1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0]
        for (index, components) in scans.enumerated() {
            let q = UInt8(redefineQuantization ? index + 1 : 1)
            data += [0xff, 0xdb, 0, 67, 0] + Array(repeating: q, count: 64)
            let interval = intervals[index]
            data += [0xff, 0xdd, 0, 4, UInt8(interval >> 8), UInt8(interval & 255)]
            data += [0xff, 0xda, 0, UInt8(6 + 2 * components.count), UInt8(components.count)]
            for component in components { data += [UInt8(component + 1), 0] }
            data += [0, 63, 0]
            var writer = BitWriter(), previous = [Int32](repeating: 0, count: 3), restart = 0
            for mcu in 0..<(columns * rows) {
                if interval > 0, mcu > 0, mcu % interval == 0 {
                    writer.emitRestartMarker(restart); restart += 1
                    previous = [0, 0, 0]
                }
                for component in components {
                    HuffmanEncoder.encodeDC(8 - previous[component], table: StandardHuffmanTables.dcLuminance, writer: &writer)
                    previous[component] = 8
                    HuffmanEncoder.encodeAC(Array(repeating: 0, count: 64), table: StandardHuffmanTables.acLuminance, writer: &writer)
                }
            }
            writer.flush(); data += writer.data
        }
        // Final post-scan changes must not retroactively alter any scan.
        data += [0xff, 0xdd, 0, 4, 0, 7]
        data += [0xff, 0xdb, 0, 67, 0] + Array(repeating: 31, count: 64)
        return data + [0xff, 0xd9]
    }

    @Test("Per-scan tables and restart intervals survive separate and mixed scans")
    func multiScanSnapshots() throws {
        var rgb = JLIDecoderConfiguration.default; rgb.sourceColorModel = .rgb
        let separate = sequential(scans: [[0], [1], [2]], intervals: [1, 2, 0], redefineQuantization: true)
        #expect(try decode(separate, configuration: rgb) == Array(repeating: [UInt8(129), 130, 131], count: 17 * 19).flatMap { $0 })
        let mixed = sequential(scans: [[2, 0], [1]], intervals: [2, 1], redefineQuantization: false)
        #expect(try decode(mixed, configuration: rgb) == Array(repeating: 129, count: 17 * 19 * 3))
        let repeated = sequential(scans: [[0, 1], [1, 2]], intervals: [0, 0], redefineQuantization: false)
        #expect(throws: JLIError.self) { try decode(repeated, configuration: rgb) }
        let incomplete = sequential(scans: [[0, 1]], intervals: [0], redefineQuantization: false)
        #expect(throws: JLIError.self) { try decode(incomplete, configuration: rgb) }
    }

    @Test("Cancellation returns no publishable RGB buffer")
    func cancellation() async throws {
        let encoded = sequential(scans: [[0, 1, 2]], intervals: [0], redefineQuantization: false)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try decode(encoded)
        }
        do { _ = try await task.value; Issue.record("Cancelled RGB decode returned pixels") }
        catch is CancellationError {}
    }

    @Test("Maximum admitted geometry has a finite row workspace without allocating an image")
    func maximumPlan() throws {
        let data: [UInt8] = [0xff, 0xd8, 0xff, 0xc0, 0, 17, 8, 8, 0, 64, 0, 3,
                            1, 0x34, 0, 2, 0x34, 0, 3, 0x34, 0,
                            0xff, 0xda, 0, 12, 3, 1, 0, 2, 0, 3, 0, 0, 63, 0, 0xff, 0xd9]
        let p = UnsafeMutableRawPointer.allocate(byteCount: 16384, alignment: 16)
        defer { p.deallocate() }
        let config = JLIDecoderConfiguration(maximumPixels: 1 << 25, maximumDecodedBytes: 384 << 20)
        try data.withUnsafeBytes { input in
            let info = try JLIDecoder().inspectBaselineRGB(input,
                headerWorkspace: UnsafeMutableRawBufferPointer(start: p, count: 16384), configuration: config)
            #expect(info.arenaByteCount == 384 << 20)
            #expect(info.outputByteCount == 96 << 20)
            #expect(info.workspaceByteCount == 10_746_720)
        }
    }

    @Test("Malformed accumulating DC coefficients throw instead of trapping")
    func coefficientOverflow() throws {
        let width = 128, height = 16385
        var data: [UInt8] = [0xff, 0xd8, 0xff, 0xc0, 0, 17, 8, UInt8(height >> 8), UInt8(height & 255), 0, UInt8(width), 3,
                            1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0]
        // Single-bit DC category16 and AC EOB codes.
        for table: UInt8 in [0, 0x10] {
            data += [0xff, 0xc4, 0, 20, table, 1] + Array(repeating: 0, count: 15) + [table == 0 ? 16 : 0]
        }
        data += [0xff, 0xda, 0, 12, 3, 1, 0, 2, 0, 3, 0, 0, 63, 0]
        var writer = BitWriter()
        for _ in 0..<(16 * 2049 * 3) {
            writer.writeBits(0, count: 1); writer.writeBits(65535, count: 16); writer.writeBits(0, count: 1)
        }
        writer.flush(); data += writer.data; data += [0xff, 0xd9]
        #expect(throws: JLIError.self) { try decode(data) }
    }
}
