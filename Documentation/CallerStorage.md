# Caller-owned decode storage

The 0.6.0 core APIs return nonthrowing `JLICoreOutcome` values. They use supplied
input, workspace and output with concrete parser control records and shared
numerical kernels. Existing throwing decode APIs remain compatibility adapters.
Complete allocation qualification also requires the recorded compiler/runtime
profile, admitted caller stack/control storage and a qualified cancellation callback.

`inspectLosslessMonochromeCore` and `decodeLosslessMonochromeCore` reuse the canonical marker,
Huffman and lossless prediction implementations with borrowed input and fixed caller
scratch. Output is unsigned little-endian UInt16. A caller may interpret signed
DICOM containers under its existing descriptor rules. Predictor, restart and
point-transform semantics are retained. No encoded copy or full Int32 plane is
required. This additive profile supports one monochrome SOF3 scan.

`inspectBaselineRGBCore` and `decodeBaselineRGBCore` support full-resolution sequential
8-bit three-component JPEG. The caller supplies an aligned raw arena of 12 bytes
per pixel and the reported workspace. Output occupies only the first 3 bytes per
pixel, but the full arena must remain retained and charged. Never account it as a
3-byte-per-pixel allocation unless an independently admitted compact copy is made.

The decoder uses an MCU-row coefficient strip and shared IDCT scratch, reconstructs
component planes in three Float slots, expands each component backwards using a
three-row cache, then converts 1,024-pixel tiles forward into the RGB prefix. All
borrowed pointers are synchronous. Caller spans must be disjoint and exclusively
owned; failed/cancelled output is not publishable.

For width W, B_i = ceil(W / (8*h_max)) * h_i * v_i, scratch is
59,232 + 256*sum(B_i) + 512*max(B_i) + 12*W bytes on the supported 64-bit platforms.
At W <= 16,384 and sampling factors 1...4 this is at most 10,746,720 bytes. The
arena is separately checked against caller admission and overflow limits.

Sequential separate/mixed component scans snapshot DHT, DQT and DRI state at SOS.
This corrects the legacy owned baseline path's first-scan-only behavior; do not
claim parity with that behavior for multi-scan images. Undersampled luminance and
XYB planes use generic expansion, replacing previously unsafe full-size indexing.
Malformed cumulative DC overflow returns a scalar failure. Legacy normal images preserve their
canonical reconstruction and conversion math.

Tests cover independent lossless fixtures, all predictors, point transforms,
restarts, odd dimensions, color modes, scan-state changes, malformed coefficients,
exact capacities, overlap, canaries and cancellation. The core uses fixed scalar/SIMD kernels and supplied reconstruction tables instead
of opaque Accelerate scratch. Internal concrete result carriers avoid cold generic
metadata initialization on the selected compiled path. Runtime and final caller
qualification are separate from source-level tests and explicit buffer capacities.

The shared image-contract APIs (`JLIContractCodec`, `Image`, `ImageDestination`)
remain available with their existing storage semantics. They use owned parser and
workspace allocations and are outside this core allocation qualification. Shared
pixel storage or an `OperationReport` is not evidence of a total operation bound.
