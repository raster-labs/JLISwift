// SPDX-License-Identifier: MIT
//
// Caller memory, borrowed for the duration of one synchronous codec call.
//
// These are deliberately not owners and deliberately not Sendable. The
// contract surface creates one inside a storage borrow and it dies with that
// borrow, so the pointer cannot outlive the allocation, be stored, or cross an
// `await` (MEM-08). The owner types live in the contract layer; the codec
// internals only ever see this.

import Foundation

/// A caller plane the codec may read.
struct BorrowedSamplePlane {
    let bytes: UnsafeRawBufferPointer
    /// Distance in bytes between the starts of consecutive rows. May exceed
    /// the row payload; the bytes between are never read.
    let rowBytes: Int
}

/// A caller plane the codec may write.
struct BorrowedSampleDestination {
    let bytes: UnsafeMutableRawBufferPointer
    /// Distance in bytes between the starts of consecutive rows. May exceed
    /// the row payload; the bytes between are never written, so caller
    /// sentinels there survive.
    let rowBytes: Int
}
