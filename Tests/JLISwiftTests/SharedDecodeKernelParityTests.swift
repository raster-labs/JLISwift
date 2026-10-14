import Accelerate
import Testing
@testable import JLISwift

@Suite("Shared decode numerical migration")
struct SharedDecodeKernelParityTests {
    @Test("IDCT matches released Accelerate sample bytes", arguments: [1, 2, 3, 8, 17, 33, 129, 8192])
    func inverseDCT(blocks: Int) {
        let count = blocks * 64
        var coefficients = [Int32](repeating: 0, count: count)
        var seed: UInt64 = 0xC0DEC0DE
        for index in coefficients.indices {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let random = Int32(truncatingIfNeeded: seed >> 32)
            // Mix sparse, typical and adversarial finite coefficients.
            let mode = (index / 64) % 4
            coefficients[index] = mode == 0 ? (index % 64 == 0 ? random % 1024 : 0) :
                mode == 1 ? random % 32 : mode == 2 ? random % 2048 : random
        }
        let quantization = (0..<64).map { Float(1 + ($0 * 7) % 255) }
        let old = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let new = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { old.deallocate(); new.deallocate(); scratch.deallocate() }
        coefficients.withUnsafeBufferPointer { zz in
            quantization.withUnsafeBufferPointer { qt in
                AccelerateDSP.withOwnedReconstructionTables { tables in
                    ReleasedAccelerateDecodeOracle.inverseDCTBatchDequantized(zigzag: zz.baseAddress!, quantTable: qt.baseAddress!, output: old, scratch: scratch, blockCount: blocks, tables: tables)
                    AccelerateDSP.inverseDCTBatchDequantized(zigzag: zz.baseAddress!, quantTable: qt.baseAddress!, output: new, scratch: scratch, blockCount: blocks, tables: tables)
                }
            }
        }
        var changedFloats = 0, changedSamples = 0
        var maximum: Float = 0
        for index in 0..<count {
            if old[index].bitPattern != new[index].bitPattern { changedFloats += 1 }
            maximum = max(maximum, abs(old[index] - new[index]))
            let before = UInt8(clamping: Int(min(max(old[index] + 128, 0), 255).rounded()))
            let after = UInt8(clamping: Int(min(max(new[index] + 128, 0), 255).rounded()))
            if before != after { changedSamples += 1 }
        }
        print("SHARED-IDCT blocks=\(blocks) floatChanges=\(changedFloats) sampleChanges=\(changedSamples) maxFloatDifference=\(maximum)")
        #expect(changedFloats == 0)
        #expect(changedSamples == 0)
    }

    @Test("RGB conversion preserves released operation order and ties")
    func rgbConversion() {
        let count = 65_537
        var y = [Float](repeating: 0, count: count)
        var cb = y, cr = y
        var seed: UInt64 = 0xDEC0DE
        for index in 0..<count {
            // Half values exercise conversion ties; fractional and random chroma
            // exercise multiply/add rounding on either side of byte boundaries.
            y[index] = Float(index % 512) / 2
            if index < 512 {
                cb[index] = 128; cr[index] = 128
            } else if index < 4097 {
                cb[index] = Float((index * 17) % 2048) / 8
                cr[index] = Float((index * 91) % 2048) / 8
            } else {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                cb[index] = Float(UInt32(truncatingIfNeeded: seed >> 32)) / Float(UInt32.max) * 255
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                cr[index] = Float(UInt32(truncatingIfNeeded: seed >> 32)) / Float(UInt32.max) * 255
            }
        }
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: count * 5)
        let planes = UnsafeMutablePointer<UInt8>.allocate(capacity: count * 3)
        let old = UnsafeMutablePointer<UInt8>.allocate(capacity: count * 3)
        let new = UnsafeMutablePointer<UInt8>.allocate(capacity: count * 3)
        defer { scratch.deallocate(); planes.deallocate(); old.deallocate(); new.deallocate() }
        var oracleFloats: [Float] = []
        y.withUnsafeBufferPointer { yp in
            cb.withUnsafeBufferPointer { cp in
                cr.withUnsafeBufferPointer { rp in
                    ReleasedAccelerateDecodeOracle.imageYCbCrToRGB(y: yp.baseAddress!, cb: cp.baseAddress!, cr: rp.baseAddress!, pixelCount: count, scratch: scratch, planes: planes, output: old)
                    oracleFloats = Array(UnsafeBufferPointer(start: scratch, count: count * 5))
                    AccelerateDSP.imageYCbCrToRGB(y: yp.baseAddress!, cb: cp.baseAddress!, cr: rp.baseAddress!, pixelCount: count, scratch: scratch, planes: planes, output: new)
                }
            }
        }
        let changes = (0..<(count * 3)).reduce(0) { $0 + (old[$1] == new[$1] ? 0 : 1) }
        print("SHARED-RGB pixels=\(count) channelChanges=\(changes)")
        for index in (0..<(count * 3)).filter({ old[$0] != new[$0] }).prefix(8) {
            let pixel = index / 3, channel = index % 3, position = (channel + 2) * count + pixel
            print("SHARED-RGB-DIFF pixel=\(pixel) channel=\(channel) y=\(y[pixel]) cb=\(cb[pixel]) cr=\(cr[pixel]) old=\(old[index]) new=\(new[index]) oldFloat=\(oracleFloats[position]) newFloat=\(scratch[position])")
        }
        #expect(changes == 0)
    }
}
