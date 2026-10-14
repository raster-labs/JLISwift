// SPDX-License-Identifier: Apache-2.0

/// Synchronous cancellation without a captured Swift closure or task-runtime call.
/// The caller owns `context` until the operation returns. The function must be
/// thread-safe and allocation-free; it may read a caller-owned atomic flag.
public struct JLICancellation {
    public typealias Check = @convention(c) (UnsafeRawPointer?) -> Bool
    public let context: UnsafeRawPointer?
    public let isCancelled: Check?
    public init(context: UnsafeRawPointer? = nil, isCancelled: Check? = nil) {
        self.context = context; self.isCancelled = isCancelled
    }
    public static var never: Self { Self() }
    internal static var task: Self { Self(isCancelled: { _ in Task.isCancelled }) }
    internal func check() -> JLICoreOutcome<Void> {
        if isCancelled?(context) == true { return .failure(JLICoreFailure(code: 1, kind: .cancelled)) }
        return .success(())
    }
}

/// One shared parser collection representation. Owned consumers retain Arrays;
/// caller consumers retain only a borrowed workspace span. No owned backing is
/// created or mutated by the borrowed branch. Elements in caller storage are
/// initialized in place and explicitly released by the storage owner.
internal struct JPEGStorageArray<Element>: RandomAccessCollection, @unchecked Sendable {
    typealias Index = Int
    private var owned: [Element] = []
    private let borrowed: UnsafeMutableBufferPointer<Element>?
    private(set) var count: Int = 0
    init() { borrowed = nil }
    init(_ owned: [Element]) { self.owned = owned; borrowed = nil; count = owned.count }
    init(borrowing buffer: UnsafeMutableBufferPointer<Element>) { borrowed = buffer }
    var startIndex: Int { 0 }
    var endIndex: Int { count }
    subscript(index: Int) -> Element {
        precondition(index >= 0 && index < count)
        return borrowed?[index] ?? owned[index]
    }
    mutating func append(_ element: Element) {
        if let borrowed {
            precondition(count < borrowed.count)
            borrowed.baseAddress!.advanced(by: count).initialize(to: element)
        } else { owned.append(element) }
        count += 1
    }
}

internal typealias JPEGScanComponent = (componentSelector: UInt8, dcTableId: Int, acTableId: Int)

/// Borrowed parsing records are separately destroyed because scan records
/// contain empty compatibility collections even though those collections never
/// allocate backing on the caller path.
internal struct JPEGCallerRecords {
    static let byteCount = 4096
    private let frame: UnsafeMutableBufferPointer<JPEGComponentInfo>
    private let components: UnsafeMutableBufferPointer<JPEGScanComponent>
    private let scans: UnsafeMutableBufferPointer<JPEGScanData>
    private let counts: UnsafeMutableBufferPointer<Int>
    init(_ bytes: UnsafeMutableRawBufferPointer) {
        precondition(bytes.count >= Self.byteCount)
        var offset = 0
        func buffer<T>(_ type: T.Type, _ n: Int) -> UnsafeMutableBufferPointer<T> {
            let alignment = MemoryLayout<T>.alignment
            offset = (offset + alignment - 1) & ~(alignment - 1)
            let start = offset; offset += MemoryLayout<T>.stride * n
            precondition(offset <= Self.byteCount)
            return UnsafeMutableRawBufferPointer(rebasing: bytes[start..<offset]).bindMemory(to: T.self)
        }
        frame = buffer(JPEGComponentInfo.self, 3)
        components = buffer(JPEGScanComponent.self, 9)
        scans = buffer(JPEGScanData.self, 3)
        counts = buffer(Int.self, 3); counts.initialize(repeating: 0)
    }
    func frameStorage() -> JPEGStorageArray<JPEGComponentInfo> { JPEGStorageArray(borrowing: frame) }
    func componentStorage() -> JPEGStorageArray<JPEGScanComponent> {
        let index = counts[1]
        precondition(index < 3)
        counts[1] += 1
        return JPEGStorageArray(borrowing: UnsafeMutableBufferPointer(rebasing: components[(index * 3)..<(index * 3 + 3)]))
    }
    func scanStorage() -> JPEGStorageArray<JPEGScanData> { JPEGStorageArray(borrowing: scans) }
    func didAppendScan() { counts[2] += 1 }
    func destroy() { scans.baseAddress!.deinitialize(count: counts[2]); counts[2] = 0 }
}

internal struct JLITriple<Element>: RandomAccessCollection {
    private var a: Element, b: Element, c: Element
    init(_ value: (Int) -> Element) { a = value(0); b = value(1); c = value(2) }
    var startIndex: Int { 0 }; var endIndex: Int { 3 }
    subscript(index: Int) -> Element {
        get { switch index { case 0: return a; case 1: return b; case 2: return c; default: preconditionFailure() } }
        set { switch index { case 0: a = newValue; case 1: b = newValue; case 2: c = newValue; default: preconditionFailure() } }
    }
}
