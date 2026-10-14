# JLISwift 0.6.0

Baseline RGB and lossless monochrome decoding now support caller-owned input,
workspace and output through nonthrowing `JLICoreOutcome` APIs. The core reuses
the canonical marker parser, entropy, prediction, reconstruction and color kernels.

- Fixed caller workspace and concrete parser control records avoid variable owned
  control backing and cold generic/Error witness initialization on the selected path.
- Baseline RGB retains a full 12-byte-per-pixel arena even after compacting visible
  output to 3 bytes per pixel. Capacity, alignment and overlap checks precede use.
- Synchronous borrowed C cancellation callbacks cover parser, row and tile boundaries.
  Failure/cancellation may leave partial output, which must be discarded.
- Shared SIMD inverse-DCT and color conversion preserve the established decode
  results without opaque Accelerate scratch on the qualified core path.
- Legacy throwing decode/inspection remains available with existing semantics.
- The upstream shared image-contract APIs and padded-row storage remain available;
  their owned parser/workspace paths are outside the qualified core boundary.

Allocation claims require the recorded compiler/runtime profile, admitted caller
stack/control storage and qualified cancellation callback. This is not an arbitrary
instrumentation or total-process memory guarantee.

Validation: Swift 6.2.3 passed 275 tests in 35 suites with 95.13% line coverage
and an optimized warnings-as-errors Release build. iOS, tvOS, watchOS and visionOS
simulator builds passed. Fresh Swift 6.4 SIL/assembly renewed the selected-path
allocation evidence; see `Documentation/AllocationQualification-0.6.0.md`.
Final linked-application admission remains a consumer requirement.
