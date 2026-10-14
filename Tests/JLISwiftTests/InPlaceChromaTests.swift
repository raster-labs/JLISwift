import Testing
@testable import JLISwift

@Suite("Caller-storage chroma expansion")
struct InPlaceChromaTests {
    @Test("Reverse expansion matches canonical sampling for all accepted factor ratios")
    func allRatios() throws {
        for tw in [1, 2, 3, 7, 17, 33] {
            for th in [1, 2, 3, 9, 17] {
                for hm in 1...4 { for vm in 1...4 {
                    for hs in 1...hm { for vs in 1...vm {
                        let w = (tw * hs + hm - 1) / hm, h = (th * vs + vm - 1) / vm
                        let source = (0..<(w * h)).map { Float(($0 * 71 + 19) % 256) + Float($0 % 4) / 4 }
                        for centered in [false, true] {
                            let expected = centered ? ChromaSampling.upsampleJPEG(source, width: w, height: h,
                                targetWidth: tw, targetHeight: th, horizontalSampling: hs, verticalSampling: vs,
                                maximumHorizontalSampling: hm, maximumVerticalSampling: vm) :
                                ChromaSampling.upsample(source, width: w, height: h, targetWidth: tw, targetHeight: th)
                            var arena = source + Array(repeating: Float.nan, count: tw * th - source.count)
                            var scratch = [Float](repeating: .nan, count: 3 * w)
                            try arena.withUnsafeMutableBufferPointer { output in
                                try scratch.withUnsafeMutableBufferPointer { rows in
                                    try ChromaSampling.upsampleInPlace(output, width: w, height: h,
                                        targetWidth: tw, targetHeight: th, horizontalSampling: hs, verticalSampling: vs,
                                        maximumHorizontalSampling: hm, maximumVerticalSampling: vm,
                                        centered: centered, rowScratch: rows)
                                }
                            }
                            #expect(arena == expected, "Geometry \(tw)x\(th) \(hs)/\(hm),\(vs)/\(vm); centered \(centered)")
                        }
                    } }
                } }
            }
        }
    }
}
