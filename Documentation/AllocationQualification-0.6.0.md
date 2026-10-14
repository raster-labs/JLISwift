# JLISwift 0.6.0 allocation qualification

The four caller-storage inspect/decode entry points use the canonical marker,
entropy, reconstruction and color kernels. Qualification applies to optimized
arm64 macOS 14 code compiled in Swift 6 mode with the recorded Swift 6.4 compiler,
and the inspected macOS 27.0.1 (26A434) runtime. It does not qualify arbitrary
compiler/runtime instrumentation, the owned image-contract facade, or an embedding
application's complete operation.

The exact source and generated-code hashes are in `AllocationSource-0.6.0.json`.
The final module includes the upstream image-contract APIs. Its complete direct
branch and function-address closure was compared with the previously reviewed
caller-storage module: 116 function bodies are identical after local-label and
linker-hint normalization; four more differ only by constant-pool label numbering
with identical constant bytes. `BitReader.readBitsCore` now inlines `loadByte` and
is a scalar leaf with no calls or stack storage. An excluded owned Slice helper
calls a renamed merged destroy function whose body is identical.

Selected-path conditions remain necessary: immutable nonnil caller capture uses
supplied frame/scan/Huffman records; DQT/DHT result arrays remain empty; owned APP
payload/ICC and entropy Slice copies are excluded; empty dictionary construction
returns the immortal singleton before generic metadata or heap allocation.
Concrete ownership-result carriers avoid generic cleanup on the selected path.
Shared inverse-DCT and RGB kernels contain no Accelerate calls. The recorded math,
copy/fill, once and default ARC runtime paths are part of the local evidence.
Borrowed cancellation callbacks and their context must be separately qualified.

Lossless workspace is 6,160 bytes plus a two-byte-per-pixel destination. Baseline
requires the complete 12-byte-per-pixel arena; only its first three bytes per pixel
are visible output. Workspace is 59,232 + 256*sum(Bi) + 512*max(Bi) + 12*width,
where Bi = ceil(width/(8*hmax))*hi*vi. Source, full capacities, stack/control backing
and callback lifetime must all remain admitted through final destruction. Module
codegen review does not prove final linked application admission.

Validation on the final production source:
- Swift 6.2.3: 275 tests in 35 suites passed; 95.13% line coverage.
- Swift 6.2.3 optimized Release build passed with warnings as errors.
- iOS, tvOS, watchOS and visionOS simulator compilation passed.
- Fresh Swift 6.4 optimized SIL and assembly generated successfully. Reviewed
  core SIL uses only stack allocation instructions and no owned-table/Accelerate,
  task or compatibility-error references.

The final DICOMKit/Mayam linked probe and admission validation remain consumer
requirements; these package receipts do not declare those applications qualified.
