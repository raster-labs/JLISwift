import Foundation
import Testing
@testable import JLISwift

@Suite("Caller-owned lossless JPEG storage")
struct LosslessCallerStorageTests {
    private func withWorkspace<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        let p = UnsafeMutableRawPointer.allocate(byteCount: JLIDecoder.losslessMonochromeWorkspaceByteCount, alignment: 16)
        defer { p.deallocate() }
        return try body(UnsafeMutableRawBufferPointer(start: p, count: JLIDecoder.losslessMonochromeWorkspaceByteCount))
    }
    private func decode(_ data: [UInt8], configuration: JLIDecoderConfiguration = .default) throws -> [UInt8] {
        try withWorkspace { workspace in
            try data.withUnsafeBytes { input in
                let info = try JLIDecoder().inspectLosslessMonochrome(input, workspace: workspace, configuration: configuration)
                var output = [UInt8](repeating: 0xCD, count: info.outputByteCount + 2)
                try output.withUnsafeMutableBytes { bytes in
                    let actual = try JLIDecoder().decodeLosslessMonochrome(input,
                        into: UnsafeMutableRawBufferPointer(rebasing: bytes[1..<(bytes.count - 1)]),
                        workspace: workspace, configuration: configuration)
                    #expect(actual == info)
                }
                #expect(output.first == 0xCD && output.last == 0xCD)
                return Array(output.dropFirst().dropLast())
            }
        }
    }
    @Test("Independent libjpeg fixtures retain exact pixels")
    func independentFixtures() throws {
        let pairs: [([UInt8], [UInt8])] = [
            (LosslessTests.llP1, LosslessTests.src.flatMap { [$0, 0] }),
            (LosslessTests.llP7, LosslessTests.src.flatMap { [$0, 0] }),
            (LosslessTests.ll16, LosslessTests.src16LE),
            (LosslessTests.nlPt1, LosslessTests.nlPt1Expected.flatMap { [$0, 0] }),
            (LosslessTests.nlPt2, LosslessTests.nlPt2Expected.flatMap { [$0, 0] }),
            (LosslessRestartTests.cjpegRestart8, LosslessRestartTests.expected8.flatMap { [$0, 0] }),
            (LosslessRestartTests.cjpegRestart12, LosslessRestartTests.expected12.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
        ]
        for (input, expected) in pairs { #expect(try decode(input) == expected) }
    }
    @Test("All predictors, point transforms and restart topologies share the kernel", arguments: 1...7)
    func prediction(predictor: Int) throws {
        let width = 17, height = 21
        let pixels = (0..<(width * height)).map { UInt16(($0 * 89) & 4095) }
        let bytes = pixels.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] }
        let image = try JLIImage(width: width, height: height, pixelFormat: .uint16, colorModel: .grayscale, data: bytes)
        for rows in [0, 1, 4, 25] {
            for pt in [0, 2] {
                var config = JLIEncoderConfiguration(lossless: true, losslessPredictor: predictor)
                config.losslessPrecision = 12; config.losslessPointTransform = pt
                config.restartInterval = width * rows
                let encoded = try JLIEncoder().encode(image, configuration: config)
                let legacy = try JLIDecoder().decode(from: encoded)
                #expect(try decode(encoded) == legacy.data)
            }
        }
    }
    private func oneSample(tableID: Int = 0, category16: Bool = false) -> [UInt8] {
        var bytes: [UInt8] = [0xff, 0xd8, 0xff, 0xc3, 0, 11, 12, 0, 1, 0, 1, 1, 1, 0x11, 0]
        if category16 {
            bytes += [0xff, 0xc4, 0, 20, UInt8(tableID), 1]
            bytes += Array(repeating: 0, count: 15)
            bytes += [16]
        }
        bytes += [0xff, 0xda, 0, 8, 1, 1, UInt8(tableID << 4), 1, 0, 0, 0, 0xff, 0xd9]
        return bytes
    }
    @Test("Sparse table IDs, missing-table fallback and category 16 are preserved")
    func tableSemantics() throws {
        for id in [0, 1, 7, 15] {
            #expect(try decode(oneSample(tableID: id)) == [0, 8])
            let special = oneSample(tableID: id, category16: true)
            #expect(try decode(special) == [0, 136])
            #expect(try decode(special) == JLIDecoder().decode(from: special).data)
        }
        // Redefining DHT after the scan must not replace its active table snapshot.
        var replaced = oneSample(category16: true)
        var table: [UInt8] = [0xff, 0xc4, 0, 20, 0, 1]
        table += Array(repeating: 0, count: 15); table += [0]
        replaced.insert(contentsOf: table, at: replaced.count - 2)
        #expect(try decode(replaced) == [0, 136])
    }
    @Test("Post-scan DRI changes do not reinterpret completed lossless entropy")
    func restartIntervalSnapshot() throws {
        let fixtures: [([UInt8], [UInt8])] = [
            (LosslessTests.llP1, LosslessTests.src.flatMap { [$0, 0] }),
            (LosslessRestartTests.cjpegRestart8, LosslessRestartTests.expected8.flatMap { [$0, 0] }),
            (LosslessRestartTests.cjpegRestart12,
             LosslessRestartTests.expected12.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
        ]
        for (encoded, expected) in fixtures {
            for laterInterval in [UInt8(0), 1, 26] {
                var redefined = encoded
                redefined.insert(contentsOf: [0xff, 0xdd, 0, 4, 0, laterInterval], at: redefined.count - 2)
                #expect(try decode(redefined) == expected)
            }
        }
    }

    @Test("Caller capacities, overlapping spans and malformed structures fail")
    func invalidInput() throws {
        let data = oneSample()
        withWorkspace { workspace in
            data.withUnsafeBytes { raw in
                var short = [UInt8](repeating: 0xAA, count: 1)
                _ = short.withUnsafeMutableBytes { output in
                    #expect(throws: JLIError.self) { try JLIDecoder().decodeLosslessMonochrome(raw, into: output, workspace: workspace) }
                }
                #expect(short == [0xAA])
                #expect(throws: JLIError.self) { try JLIDecoder().decodeLosslessMonochrome(raw, into: workspace, workspace: workspace) }
                #expect(throws: JLIError.self) {
                    try JLIDecoder().inspectLosslessMonochrome(raw, workspace: UnsafeMutableRawBufferPointer(rebasing: workspace.dropLast()))
                }
            }
        }
        for malformed in [Array(data.dropLast(2)), data + data, data + [1, 2]] {
            #expect(throws: JLIError.self) { try decode(malformed) }
        }
        var config = JLIDecoderConfiguration.default
        config.maximumDecodedBytes = 2
        #expect(try decode(data, configuration: config) == [0, 8])
        config.maximumDecodedBytes = 1
        #expect(throws: JLIError.self) { try decode(data, configuration: config) }
    }
    @Test("Cancellation returns no publishable output")
    func cancellation() async throws {
        let input = oneSample()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try decode(input)
        }
        do { _ = try await task.value; Issue.record("Cancelled decode returned pixels") }
        catch is CancellationError {}
    }
}
