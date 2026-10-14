// SPDX-License-Identifier: Apache-2.0
/// An internal zero-based view. Owned construction preserves legacy Array
/// lifetimes; borrowed construction is confined to synchronous decoder calls.
struct JPEGByteView: RandomAccessCollection {
    typealias Index = Int
    private let owned: [UInt8]
    private let borrowed: UnsafeRawBufferPointer?
    init(_ bytes: [UInt8]) { owned = bytes; borrowed = nil }
    init(borrowing bytes: UnsafeRawBufferPointer) {
        owned = []; borrowed = bytes
    }
    var startIndex: Int { 0 }
    var endIndex: Int { borrowed?.count ?? owned.count }
    subscript(index: Int) -> UInt8 {
        if let borrowed { return borrowed[index] }
        return owned[index]
    }
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        if let borrowed { return try body(borrowed) }
        return try owned.withUnsafeBytes(body)
    }
}
