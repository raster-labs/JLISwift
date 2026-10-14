// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation

/// Chroma subsampling and upsampling operations.
///
/// Handles chroma plane downsampling (encoder) and upsampling (decoder)
/// for the supported subsampling modes: 4:4:4, 4:2:2, 4:2:0, and 4:0:0.
enum ChromaSampling {

    /// Raw pointers for the parallel upsample. Each row is written independently,
    /// so sharing these across `concurrentPerform` workers is safe (the buffers
    /// stay alive for the synchronous duration of the call).
    private struct UpsamplePtrs: @unchecked Sendable {
        let src: UnsafePointer<Float>
        let dst: UnsafeMutablePointer<Float>
        let sx0: UnsafePointer<Int>
        let sx1: UnsafePointer<Int>
        let fx: UnsafePointer<Float>
    }

    /// Downsamples a component plane by a factor of 2 in each specified dimension.
    ///
    /// Uses simple box filtering (averaging) for downsampling.
    ///
    /// - Parameters:
    ///   - plane: Source plane data.
    ///   - width: Source plane width.
    ///   - height: Source plane height.
    ///   - horizontally: Whether to downsample horizontally (halve width).
    ///   - vertically: Whether to downsample vertically (halve height).
    /// - Returns: Downsampled plane data and new dimensions.
    static func downsample(_ plane: [Float], width: Int, height: Int,
                           horizontally: Bool, vertically: Bool) -> (data: [Float], width: Int, height: Int) {
        guard horizontally || vertically else {
            return (plane, width, height)
        }

        let newWidth = horizontally ? (width + 1) / 2 : width
        let newHeight = vertically ? (height + 1) / 2 : height
        var result = [Float](repeating: 0, count: newWidth * newHeight)

        // 2×2 fast path (the 4:2:0 default, ~8% of a color encode): interior
        // boxes are complete, so the per-pixel edge guards and the generic
        // sum/count bookkeeping vanish — the additions keep the exact serial
        // association of the generic loop (((a+b)+c)+d, top row first), and
        // /4, /2 are exact power-of-two scalings, so output is byte-identical.
        // Odd-edge boxes (1×2 / 2×1 / 1×1) are handled in matching order.
        if horizontally && vertically {
            plane.withUnsafeBufferPointer { sp in
                result.withUnsafeMutableBufferPointer { rp in
                    let src = sp.baseAddress!, dst = rp.baseAddress!
                    let fullW = width / 2, fullH = height / 2
                    for dy in 0..<fullH {
                        let rA = (dy * 2) * width, rB = rA + width
                        let dRow = dy * newWidth
                        for dx in 0..<fullW {
                            let sx = dx * 2
                            let sum = ((src[rA + sx] + src[rA + sx + 1])
                                       + src[rB + sx]) + src[rB + sx + 1]
                            dst[dRow + dx] = sum / 4
                        }
                        if newWidth > fullW {                         // odd width: 1×2 box
                            let sx = fullW * 2
                            dst[dRow + fullW] = (src[rA + sx] + src[rB + sx]) / 2
                        }
                    }
                    if newHeight > fullH {                            // odd height: 2×1 boxes
                        let rA = (fullH * 2) * width
                        let dRow = fullH * newWidth
                        for dx in 0..<fullW {
                            let sx = dx * 2
                            dst[dRow + dx] = (src[rA + sx] + src[rA + sx + 1]) / 2
                        }
                        if newWidth > fullW {                         // odd corner: 1×1
                            dst[dRow + fullW] = src[rA + fullW * 2]
                        }
                    }
                }
            }
            return (result, newWidth, newHeight)
        }

        let hStep = horizontally ? 2 : 1
        let vStep = vertically ? 2 : 1

        for dy in 0..<newHeight {
            for dx in 0..<newWidth {
                var sum: Float = 0
                var count: Float = 0
                for vy in 0..<vStep {
                    let sy = dy * vStep + vy
                    guard sy < height else { continue }
                    for vx in 0..<hStep {
                        let sx = dx * hStep + vx
                        guard sx < width else { continue }
                        sum += plane[sy * width + sx]
                        count += 1
                    }
                }
                result[dy * newWidth + dx] = sum / count
            }
        }

        return (result, newWidth, newHeight)
    }

    /// Upsamples a component plane by a factor of 2 in each specified dimension.
    ///
    /// Uses bilinear interpolation for smooth upsampling.
    ///
    /// - Parameters:
    ///   - plane: Source plane data.
    ///   - width: Source plane width.
    ///   - height: Source plane height.
    ///   - targetWidth: Target width after upsampling.
    ///   - targetHeight: Target height after upsampling.
    /// - Returns: Upsampled plane data.
    static func upsample(_ plane: [Float], width: Int, height: Int,
                          targetWidth: Int, targetHeight: Int) -> [Float] {
        guard targetWidth != width || targetHeight != height else {
            return plane
        }

        // The x-mapping (source columns + fractional weight) is identical for
        // every row, so precompute it once instead of per pixel. The inner loop
        // then uses raw pointers for the source/destination planes, avoiding the
        // per-element copy-on-write check that dominated the decode profile.
        // Same bilinear formula and operand order → byte-identical output.
        let xScale = Float(width - 1) / Float(max(1, targetWidth - 1))
        var sx0 = [Int](repeating: 0, count: targetWidth)
        var sx1 = [Int](repeating: 0, count: targetWidth)
        var fxs = [Float](repeating: 0, count: targetWidth)
        for tx in 0..<targetWidth {
            let srcX = Float(tx) * xScale
            let x0 = min(Int(srcX), width - 1)
            sx0[tx] = x0
            sx1[tx] = min(x0 + 1, width - 1)
            fxs[tx] = srcX - Float(x0)
        }
        let yScale = Float(height - 1) / Float(max(1, targetHeight - 1))

        var result = [Float](unsafeUninitializedCapacity: targetWidth * targetHeight) {
            _, c in c = targetWidth * targetHeight
        }
        // Hoist into Sendable scalars for the parallel closure.
        let th = targetHeight, tw = targetWidth, w = width, h = height, ys = yScale
        plane.withUnsafeBufferPointer { srcBuf in
            result.withUnsafeMutableBufferPointer { dstBuf in
                sx0.withUnsafeBufferPointer { x0b in
                    sx1.withUnsafeBufferPointer { x1b in
                        fxs.withUnsafeBufferPointer { fxb in
                            let ptrs = UpsamplePtrs(
                                src: srcBuf.baseAddress!, dst: dstBuf.baseAddress!,
                                sx0: x0b.baseAddress!, sx1: x1b.baseAddress!, fx: fxb.baseAddress!)
                            // Each output row is independent → bit-identical whether
                            // computed serially or split across cores.
                            let rows: @Sendable (Int, Int) -> Void = { rowStart, rowEnd in
                                let p = ptrs.src, d = ptrs.dst
                                let X0 = ptrs.sx0, X1 = ptrs.sx1, FX = ptrs.fx
                                for ty in rowStart..<rowEnd {
                                    let srcY = Float(ty) * ys
                                    let sy0 = min(Int(srcY), h - 1)
                                    let sy1 = min(sy0 + 1, h - 1)
                                    let fy = srcY - Float(sy0)
                                    let row0 = sy0 * w, row1 = sy1 * w
                                    let drow = ty * tw
                                    for tx in 0..<tw {
                                        let x0 = X0[tx], x1 = X1[tx], fx = FX[tx]
                                        let v00 = p[row0 + x0], v10 = p[row0 + x1]
                                        let v01 = p[row1 + x0], v11 = p[row1 + x1]
                                        d[drow + tx] = bilinear(v00, v10, v01, v11, fx: fx, fy: fy)
                                    }
                                }
                            }
                            let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
                            if tw * th >= 65_536 && th >= 2 * cores {
                                let chunkRows = (th + cores - 1) / cores
                                let chunks = (th + chunkRows - 1) / chunkRows
                                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                                    let s = c * chunkRows
                                    rows(s, min(s + chunkRows, th))
                                }
                            } else {
                                rows(0, th)
                            }
                        }
                    }
                }
            }
        }
        return result
    }

    /// Reconstructs full-resolution integer JPEG components at their sample centers.
    ///
    /// Sampling ratios come from SOF, not rounded plane dimensions: an odd-width
    /// 2:1 component still has a factor of two. The usual 2:1 cases use the
    /// centered triangle filter and alternating rounding biases of libjpeg's
    /// h2v1/h1v2/h2v2 fancy upsamplers (jdsample.c). Very narrow horizontal
    /// components use replication, as libjpeg does. Round IDCT samples before
    /// filtering, then round the combined filter once before color conversion.
    /// This is separate from the floating-point/preview resizer above.
    static func upsampleJPEG(_ plane: [Float], width: Int, height: Int,
                             targetWidth: Int, targetHeight: Int,
                             horizontalSampling: Int, verticalSampling: Int,
                             maximumHorizontalSampling: Int,
                             maximumVerticalSampling: Int) -> [Float] {
        let h1 = horizontalSampling == maximumHorizontalSampling
        let v1 = verticalSampling == maximumVerticalSampling
        let h2 = horizontalSampling * 2 == maximumHorizontalSampling
        let v2 = verticalSampling * 2 == maximumVerticalSampling
        // Other sampling geometries retain the existing resampling behavior.
        guard (h1 || h2) && (v1 || v2) else {
            return upsample(plane, width: width, height: height,
                            targetWidth: targetWidth, targetHeight: targetHeight)
        }
        let samples = plane.map { $0.rounded() }
        if h1 && v1 { return samples }
        return samples.withUnsafeBufferPointer { input in
            [Float](unsafeUninitializedCapacity: targetWidth * targetHeight) { output, count in
                for y in 0..<targetHeight {
                    for x in 0..<targetWidth {
                        output[y * targetWidth + x] = jpegCenteredSample(x: x, y: y, width: width, height: height,
                            h2: h2, v2: v2, sample: { input[$1 * width + $0] })
                    }
                }
                count = targetWidth * targetHeight
            }
        }
    }

    static func bilinear(_ v00: Float, _ v10: Float, _ v01: Float, _ v11: Float,
                         fx: Float, fy: Float) -> Float {
        v00 * (1 - fx) * (1 - fy) + v10 * fx * (1 - fy) +
        v01 * (1 - fx) * fy + v11 * fx * fy
    }

    static func jpegCenteredSample(x: Int, y: Int, width: Int, height: Int,
                                   h2: Bool, v2: Bool, sample: (Int, Int) -> Float) -> Float {
        if !h2 && !v2 { return sample(min(x, width - 1), min(y, height - 1)).rounded() }
        let fancy = !h2 || width > 2
        let cy = min(v2 ? y / 2 : y, height - 1)
        let ny = min(max(cy + (y.isMultiple(of: 2) ? -1 : 1), 0), height - 1)
        let cx = min(h2 ? x / 2 : x, width - 1)
        let nx = min(max(cx + (x.isMultiple(of: 2) ? -1 : 1), 0), width - 1)
                        let current = Int(sample(cx, cy).rounded())
                        let value: Int
                        if !fancy {
                            value = current
                        } else if h2 && v2 {
                            let near = 3 * current + Int(sample(cx, ny).rounded())
                            let far = 3 * Int(sample(nx, cy).rounded()) + Int(sample(nx, ny).rounded())
                            value = (3 * near + far + (x.isMultiple(of: 2) ? 8 : 7)) >> 4
                        } else if h2 {
                            value = (3 * current + Int(sample(nx, cy).rounded())
                                     + (x.isMultiple(of: 2) ? 1 : 2)) >> 2
                        } else {
                            value = (3 * current + Int(sample(cx, ny).rounded())
                                     + (y.isMultiple(of: 2) ? 1 : 2)) >> 2
                        }
        return Float(value)
    }

    /// Expands a raw component backwards into its reserved full-resolution slot.
    /// Copy both needed source rows before writing a destination row, retaining
    /// still-needed originals across row overlap. Three row slots bound scratch.
    static func upsampleInPlace(_ plane: UnsafeMutableBufferPointer<Float>, width: Int, height: Int,
        targetWidth: Int, targetHeight: Int, horizontalSampling: Int, verticalSampling: Int,
        maximumHorizontalSampling: Int, maximumVerticalSampling: Int, centered: Bool,
        rowScratch: UnsafeMutableBufferPointer<Float>) throws {
        precondition(plane.count >= targetWidth * targetHeight && rowScratch.count >= 3 * width)
        let h1 = horizontalSampling == maximumHorizontalSampling
        let v1 = verticalSampling == maximumVerticalSampling
        let h2 = horizontalSampling * 2 == maximumHorizontalSampling
        let v2 = verticalSampling * 2 == maximumVerticalSampling
        let jpeg = centered && (h1 || h2) && (v1 || v2)
        let xScale = Float(width - 1) / Float(max(1, targetWidth - 1))
        let yScale = Float(height - 1) / Float(max(1, targetHeight - 1))
        var ids = (a: -1, b: -1, c: -1)
        func slot(_ row: Int) -> Int? {
            if ids.a == row { return 0 }; if ids.b == row { return 1 }; if ids.c == row { return 2 }
            return nil
        }
        for y in stride(from: targetHeight - 1, through: 0, by: -1) {
            try Task.checkCancellation()
            let srcY = Float(y) * yScale
            let row0: Int, row1: Int
            if jpeg {
                row0 = min(v2 ? y / 2 : y, height - 1)
                row1 = min(max(row0 + (y.isMultiple(of: 2) ? -1 : 1), 0), height - 1)
            } else {
                row0 = min(Int(srcY), height - 1); row1 = min(row0 + 1, height - 1)
            }
            func cache(_ row: Int) {
                if slot(row) != nil { return }
                let index: Int
                if ids.a != row0 && ids.a != row1 { index = 0; ids.a = row }
                else if ids.b != row0 && ids.b != row1 { index = 1; ids.b = row }
                else { index = 2; ids.c = row }
                for x in 0..<width { rowScratch[index * width + x] = plane[row * width + x] }
            }
            cache(row0); cache(row1)
            guard let slot0 = slot(row0), let slot1 = slot(row1) else { preconditionFailure("Missing cached row") }
            let fy = srcY - Float(row0)
            for x in 0..<targetWidth {
                let value: Float
                if jpeg {
                    value = jpegCenteredSample(x: x, y: y, width: width, height: height, h2: h2, v2: v2) { sx, sy in
                        rowScratch[(sy == row0 ? slot0 : slot1) * width + sx]
                    }
                } else if width == targetWidth && height == targetHeight {
                    value = rowScratch[slot0 * width + x]
                } else {
                    let srcX = Float(x) * xScale
                    let x0 = min(Int(srcX), width - 1), x1 = min(x0 + 1, width - 1)
                    value = bilinear(rowScratch[slot0 * width + x0], rowScratch[slot0 * width + x1],
                        rowScratch[slot1 * width + x0], rowScratch[slot1 * width + x1], fx: srcX - Float(x0), fy: fy)
                }
                plane[y * targetWidth + x] = value
            }
        }
    }

    /// Returns the horizontal and vertical sampling factors for a subsampling mode.
    static func samplingFactors(for mode: JLIChromaSubsampling) -> (h: Int, v: Int) {
        switch mode {
        case .yuv444: return (1, 1)
        case .yuv422: return (2, 1)
        case .yuv420: return (2, 2)
        case .yuv400: return (1, 1)  // Grayscale, no chroma
        }
    }
}
