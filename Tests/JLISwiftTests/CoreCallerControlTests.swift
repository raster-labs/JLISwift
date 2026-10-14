import Foundation
import Testing
@testable import JLISwift

/// The test owns its allocations. Core receives only synchronous borrowed spans
/// and a thin C callback; compatibility formatting is tested separately.
@Suite("Caller core control storage")
struct CoreCallerControlTests {
    private struct CancellationState { var calls = 0; var stopAt = Int.max }
    private static let cancellationCheck: JLICancellation.Check = { raw in
        guard let raw else { return false }
        let state = UnsafeMutableRawPointer(mutating: raw).assumingMemoryBound(to: CancellationState.self)
        state.pointee.calls += 1
        return state.pointee.calls >= state.pointee.stopAt
    }

    private func checkCancellationAndReuse<Value>(
        run: (JLICancellation) -> JLICoreOutcome<Value>,
        verify: () -> Void
    ) {
        var state = CancellationState()
        withUnsafeMutablePointer(to: &state) { context in
            let cancellation = JLICancellation(context: UnsafeRawPointer(context), isCancelled: Self.cancellationCheck)
            guard case .success = run(cancellation) else {
                Issue.record("Initial core decode failed"); return
            }
            verify()
            let checkpoints = context.pointee.calls
            #expect(checkpoints > 0)
            for stop in Set([1, max(1, checkpoints / 2), checkpoints]) {
                context.pointee = CancellationState(calls: 0, stopAt: stop)
                switch run(cancellation) {
                case .success: Issue.record("Core returned a result after cancellation checkpoint \(stop)")
                case .failure(let failure):
                    #expect(failure.kind == .cancelled && failure.code == 1)
                    #expect(context.pointee.calls == stop)
                }
                // The same buffers remain valid after a parser/kernel failure.
                guard case .success = run(.never) else {
                    Issue.record("Core could not reuse buffers after cancellation"); return
                }
                verify()
            }
        }
    }

    @Test("Lossless core has scalar failures and reusable admitted storage")
    func losslessControl() throws {
        let data = LosslessRestartTests.cjpegRestart12
        let expected = LosslessRestartTests.expected12.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] }
        let work = UnsafeMutableRawPointer.allocate(byteCount: JLIDecoder.losslessMonochromeWorkspaceByteCount, alignment: 16)
        let pixels = UnsafeMutableRawPointer.allocate(byteCount: expected.count + 32, alignment: 16)
        defer { work.deallocate(); pixels.deallocate() }
        pixels.initializeMemory(as: UInt8.self, repeating: 0xA7, count: expected.count + 32)
        let workspace = UnsafeMutableRawBufferPointer(start: work, count: JLIDecoder.losslessMonochromeWorkspaceByteCount)
        let output = UnsafeMutableRawBufferPointer(start: pixels + 16, count: expected.count)
        data.withUnsafeBytes { input in
            guard case .success(let info) = JLIDecoder().inspectLosslessMonochromeCore(input, workspace: workspace) else { Issue.record("Core inspection failed"); return }
            #expect(info.outputByteCount == expected.count && info.precision == 12)
            checkCancellationAndReuse(run: { cancellation in
                JLIDecoder().decodeLosslessMonochromeCore(input, into: output, workspace: workspace, cancellation: cancellation)
            }, verify: {
                #expect(Array(output) == expected)
                for i in 0..<16 {
                    #expect(pixels.load(fromByteOffset: i, as: UInt8.self) == 0xA7)
                    #expect(pixels.load(fromByteOffset: 16 + expected.count + i, as: UInt8.self) == 0xA7)
                }
            })
            switch JLIDecoder().inspectLosslessMonochromeCore(input, workspace: UnsafeMutableRawBufferPointer(rebasing: workspace.dropLast())) {
            case .success: Issue.record("Insufficient workspace accepted")
            case .failure(let failure): #expect(failure.kind == .decoding && failure.code == 168)
            }
            guard case .success = JLIDecoder().decodeLosslessMonochromeCore(input, into: output, workspace: workspace) else {
                Issue.record("Core decode failed after rejected workspace"); return
            }
            #expect(Array(output) == expected)
        }
    }

    @Test("Baseline core retains independent reference pixels and scalar cancellation",
          arguments: ChromaReferenceFixtures.all.filter { $0.name.hasPrefix("baseline_") })
    func baselineControl(fixture: ChromaReferenceFixtures.Fixture) throws {
        let data = try #require(Data(base64Encoded: fixture.jpeg))
        let expected = try #require(Data(base64Encoded: fixture.rgb))
        let header = UnsafeMutableRawPointer.allocate(byteCount: JLIDecoder.baselineHeaderWorkspaceByteCount, alignment: 16)
        defer { header.deallocate() }
        let legacy = try JLIDecoder().decode(from: Array(data)).data
        data.withUnsafeBytes { input in
            guard case .success(let info) = JLIDecoder().inspectBaselineRGBCore(input, headerWorkspace: .init(start: header, count: JLIDecoder.baselineHeaderWorkspaceByteCount)) else { Issue.record("Core inspection failed"); return }
            let work = UnsafeMutableRawPointer.allocate(byteCount: info.workspaceByteCount, alignment: 16)
            let pixels = UnsafeMutableRawPointer.allocate(byteCount: info.arenaByteCount, alignment: 16)
            defer { work.deallocate(); pixels.deallocate() }
            let workspace = UnsafeMutableRawBufferPointer(start: work, count: info.workspaceByteCount)
            let arena = UnsafeMutableRawBufferPointer(start: pixels, count: info.arenaByteCount)
            checkCancellationAndReuse(run: { cancellation in
                JLIDecoder().decodeBaselineRGBCore(input, arena: arena, workspace: workspace, cancellation: cancellation)
            }, verify: {
                let actual = Array(arena.prefix(info.outputByteCount))
                #expect(actual == legacy)
                #expect(zip(actual, expected).allSatisfy { abs(Int($0) - Int($1)) <= 3 })
            })
        }
    }

    @Test("Value parser failures preserve compatibility error values")
    func failureCompatibility() throws {
        let work = UnsafeMutableRawPointer.allocate(byteCount: JLIDecoder.losslessMonochromeWorkspaceByteCount, alignment: 16)
        defer { work.deallocate() }
        let workspace = UnsafeMutableRawBufferPointer(start: work, count: JLIDecoder.losslessMonochromeWorkspaceByteCount)
        let invalid: [UInt8] = [0, 1, 2, 3]
        invalid.withUnsafeBytes { input in
            switch JLIDecoder().inspectLosslessMonochromeCore(input, workspace: workspace) {
            case .success: Issue.record("Invalid SOI accepted")
            case .failure(let failure): #expect(failure.kind == .invalidJPEG && failure.code == 108)
            }
            do {
                _ = try JLIDecoder().inspectLosslessMonochrome(input, workspace: workspace)
                Issue.record("Compatibility API accepted invalid SOI")
            } catch JLIError.invalidJPEGData {
            } catch {
                Issue.record("Compatibility API changed error type: \(error)")
            }
        }
    }

    @Test("Entropy failures propagate as values and leave caller storage reusable")
    func entropyFailureAndReuse() {
        // A complete one-sample SOF3 header with no entropy byte. Inspection is
        // structural; the canonical Huffman reader must report the missing bit.
        let header: [UInt8] = [0xff, 0xd8, 0xff, 0xc3, 0, 11, 12, 0, 1, 0, 1, 1, 1, 0x11, 0,
                               0xff, 0xda, 0, 8, 1, 1, 0, 1, 0, 0]
        let work = UnsafeMutableRawPointer.allocate(byteCount: JLIDecoder.losslessMonochromeWorkspaceByteCount, alignment: 16)
        defer { work.deallocate() }
        let workspace = UnsafeMutableRawBufferPointer(start: work, count: JLIDecoder.losslessMonochromeWorkspaceByteCount)
        var guarded = [UInt8](repeating: 0xA7, count: 4)
        for entropy in [[], [UInt8(0)]] {
            let encoded = header + entropy + [0xff, 0xd9]
            encoded.withUnsafeBytes { input in
                guard case .success = JLIDecoder().inspectLosslessMonochromeCore(input, workspace: workspace) else {
                    Issue.record("Complete frame header rejected"); return
                }
                guarded.withUnsafeMutableBytes { bytes in
                    let output = UnsafeMutableRawBufferPointer(rebasing: bytes[1..<3])
                    switch JLIDecoder().decodeLosslessMonochromeCore(input, into: output, workspace: workspace) {
                    case .success:
                        #expect(!entropy.isEmpty)
                        #expect(output[0] == 0 && output[1] == 8)
                    case .failure(let failure):
                        #expect(entropy.isEmpty)
                        #expect(failure.kind == .decoding && failure.code == 124)
                    }
                }
            }
            #expect(guarded[0] == 0xA7 && guarded[3] == 0xA7)
        }
    }
}
