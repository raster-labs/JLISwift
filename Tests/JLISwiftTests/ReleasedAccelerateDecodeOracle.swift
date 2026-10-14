// Test-only snapshot of the v0.5.2-derived shared decode kernels before the
// caller-core allocation closure. It is never part of the library target.
import Accelerate
@testable import JLISwift

enum ReleasedAccelerateDecodeOracle {
    static func inverseDCTBatchDequantized(
        zigzag: UnsafePointer<Int32>, quantTable qt: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>, scratch: UnsafeMutablePointer<Float>,
        blockCount n: Int, tables: AccelerateDSP.ReconstructionTables
    ) {
        guard n > 0 else { return }
        let eightN = vDSP_Length(8 * n)
        let rowStride = 8 * n

        // Fused pack: M[r·8N + 8i + c] = dequant(zigzag coefficient at natural
        // position 8r+c) — replaces inverse-zigzag scatter + dequant sweep + pack
        // memcpy with one pass.
        for i in 0..<n {
            let src = zigzag + 64 * i
            for r in 0..<8 {
                let dst = scratch + r * rowStride + 8 * i
                let qrow = qt + 8 * r
                let zrow = tables.inverseZigzag + 8 * r
                for c in 0..<8 {
                    dst[c] = Float(src[zrow[c]]) * qrow[c]
                }
            }
        }

        // Pass 1: T = Cᵀ · M (8 × 8N).
        vDSP_mmul(tables.transposedDCT, 1, scratch, 1, output, 1, 8, eightN, 8)

        // Rearrange T → V (8N × 8 per-block-contig).
        for i in 0..<n {
            for r in 0..<8 {
                memcpy(scratch + 64 * i + 8 * r,
                       output + r * rowStride + 8 * i,
                       8 * MemoryLayout<Float>.size)
            }
        }

        // Pass 2: f = V · C (8N × 8). Output per-block-contig.
        vDSP_mmul(scratch, 1, tables.dct, 1, output, 1, eightN, 8, 8)
    }

    static func imageYCbCrToRGB(y yb: UnsafePointer<Float>, cb cbb: UnsafePointer<Float>,
        cr crb: UnsafePointer<Float>, pixelCount: Int, scratch: UnsafeMutablePointer<Float>,
        planes: UnsafeMutablePointer<UInt8>, output: UnsafeMutableRawPointer) {
        let n = vDSP_Length(pixelCount)
        let cbS = scratch, crS = scratch + pixelCount, r = scratch + pixelCount * 2
        let g = scratch + pixelCount * 3, b = scratch + pixelCount * 4
        var neg128: Float = -128.0
        var rCr: Float = 1.402, gCb: Float = -0.344136, gCr: Float = -0.714136, bCb: Float = 1.772
        var lo: Float = 0.0, hi: Float = 255.0
                    vDSP_vsadd(cbb, 1, &neg128, cbS, 1, n)
                    vDSP_vsadd(crb, 1, &neg128, crS, 1, n)
                    // R = Y + 1.402 Cr',  G = Y - 0.344136 Cb' - 0.714136 Cr',  B = Y + 1.772 Cb'
                    vDSP_vsma(crS, 1, &rCr, yb, 1, r, 1, n)
                    vDSP_vsmul(cbS, 1, &gCb, g, 1, n)
                    vDSP_vsma(crS, 1, &gCr, g, 1, g, 1, n)
                    vDSP_vadd(yb, 1, g, 1, g, 1, n)
                    vDSP_vsma(cbS, 1, &bCb, yb, 1, b, 1, n)
                    vDSP_vclip(r, 1, &lo, &hi, r, 1, n)
                    vDSP_vclip(g, 1, &lo, &hi, g, 1, n)
                    vDSP_vclip(b, 1, &lo, &hi, b, 1, n)
        let pr = planes, pg = pr + pixelCount, pb = pr + pixelCount * 2
        vDSP_vfixru8(r, 1, pr, 1, n); vDSP_vfixru8(g, 1, pg, 1, n); vDSP_vfixru8(b, 1, pb, 1, n)
        var sR = vImage_Buffer(data: pr, height: 1, width: vImagePixelCount(pixelCount), rowBytes: pixelCount)
        var sG = vImage_Buffer(data: pg, height: 1, width: vImagePixelCount(pixelCount), rowBytes: pixelCount)
        var sB = vImage_Buffer(data: pb, height: 1, width: vImagePixelCount(pixelCount), rowBytes: pixelCount)
        var dst = vImage_Buffer(data: output, height: 1, width: vImagePixelCount(pixelCount), rowBytes: pixelCount * 3)
        vImageConvert_Planar8toRGB888(&sR, &sG, &sB, &dst, vImage_Flags(kvImageNoFlags))
    }

}
