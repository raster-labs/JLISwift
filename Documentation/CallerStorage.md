# Caller-owned decode storage

Local candidate based on JLISwift 0.5.2. Existing owned decode APIs remain available.
This is a payload-capacity API, not a complete Swift/Accelerate heap bound.

`inspectLosslessMonochrome` and `decodeLosslessMonochrome` reuse the canonical marker,
Huffman and lossless prediction implementations with borrowed input and fixed caller
scratch. Output is unsigned little-endian UInt16. A caller may interpret signed
DICOM containers under its existing descriptor rules. Predictor, restart and
point-transform semantics are retained. No encoded copy or full Int32 plane is
required. This additive profile supports one monochrome SOF3 scan.

`inspectBaselineRGB` and `decodeBaselineRGB` support full-resolution sequential
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
Malformed cumulative DC overflow throws. Legacy normal images preserve their
canonical reconstruction and conversion math.

Tests cover independent lossless fixtures, all predictors, point transforms,
restarts, odd dimensions, color modes, scan-state changes, malformed coefficients,
exact capacities, overlap, canaries and cancellation. Fixed lazy ICC/DCT data and
Swift/parser/control allocations remain outside the reported payload capacity.
