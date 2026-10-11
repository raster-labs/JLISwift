// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Raster Lab. All rights reserved.

import Foundation
import Testing
@testable import JLISwift

@Suite("Independent libjpeg chroma reconstruction")
struct ChromaReferenceTests {
    @Test("Sharp color edges, odd dimensions and tiny JPEGs match independent RGB", arguments: ChromaReferenceFixtures.all)
    func independentRGB(_ fixture: ChromaReferenceFixtures.Fixture) throws {
        let jpeg = try #require(Data(base64Encoded: fixture.jpeg))
        let reference = try #require(Data(base64Encoded: fixture.rgb))
        let image = try JLIDecoder().decode(from: Array(jpeg))
        #expect(image.width == fixture.width && image.height == fixture.height)
        #expect(image.colorModel == .rgb && image.pixelFormat == .uint8)
        try #require(image.data.count == reference.count)
        let differences = zip(image.data, reference).map { abs(Int($0) - Int($1)) }
        let maximum = differences.max() ?? 0
        print("CHROMA-REFERENCE \(fixture.name) max=\(maximum) channelsOver3=\(differences.filter { $0 > 3 }.count)")
        #expect(maximum <= 3, "\(fixture.name): maximum RGB channel difference \(maximum) exceeds 3")
    }
}

extension ChromaReferenceFixtures.Fixture: CustomTestStringConvertible {
    var testDescription: String { name }
}
