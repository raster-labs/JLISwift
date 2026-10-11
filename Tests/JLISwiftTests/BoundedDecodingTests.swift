import Testing
@testable import JLISwift

@Suite("Bounded complete JPEG frames")
struct BoundedDecodingTests {
    func fixture() throws -> [UInt8] {
        try JLIEncoder().encode(JLIImage(width: 8, height: 8, pixelFormat: .uint8,
                                        colorModel: .grayscale, data: [UInt8](repeating: 73, count: 64)))
    }

    @Test func rejectsTruncatedConcatenatedAndGarbage() throws {
        let data = try fixture()
        for bad in [Array(data.dropLast(2)), data + data, data + [1, 2]] {
            #expect(throws: JLIError.self) { try JLIDecoder().decode(from: bad) }
        }
        let padded = data.count % 2 == 1 ? data + [0] : data
        #expect(try JLIDecoder().decode(from: padded).data == [UInt8](repeating: 73, count: 64))
    }

    @Test func boundsBeforeSampleAllocation() throws {
        let data = try fixture()
        for config in [JLIDecoderConfiguration(maximumEncodedBytes: 2),
                       JLIDecoderConfiguration(maximumPixels: 63),
                       JLIDecoderConfiguration(maximumDecodedBytes: 63)] {
            #expect(throws: JLIError.self) { try JLIDecoder().decode(from: data, configuration: config) }
        }
    }

    @Test func refusesColorRelabeling() throws {
        let data = try fixture()
        #expect(throws: JLIError.self) {
            try JLIDecoder().decode(from: data, configuration: .init(outputColorModel: .rgb))
        }
    }

    @Test func rawRGBComponentsRemainRGB() throws {
        // A constant DCT plane reconstructs its DC value. Encode pretransformed planes,
        // then signal untransformed RGB via Adobe APP14; expected output is analytical.
        let samples: [UInt8] = (0..<64).flatMap { _ in [UInt8(210), 70, 25] }
        let image = try JLIImage(width: 8, height: 8, pixelFormat: .uint8, colorModel: .yCbCr, data: samples)
        var config = JLIEncoderConfiguration.default
        config.chromaSubsampling = .yuv444
        config.quality = 100
        let stream = try JLIEncoder().encode(image, configuration: config)
        let adobe: [UInt8] = [0xff, 0xee, 0, 14, 65, 100, 111, 98, 101, 0, 100, 0, 0, 0, 0, 0]
        let rawRGB = Array(stream.prefix(2)) + adobe + Array(stream.dropFirst(2))
        let result = try JLIDecoder().decode(from: rawRGB)
        #expect(result.colorModel == .rgb)
        #expect(result.data.count == samples.count)
        #expect(zip(result.data, samples).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
    }
}
