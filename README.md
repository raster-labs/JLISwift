# JLISwift

A native-Swift JPEG codec for Apple platforms, with Accelerate-backed DSP.

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%20|%20iOS%20|%20tvOS%20|%20watchOS%20|%20visionOS-blue.svg)](#platform-support)
[![License](https://img.shields.io/badge/License-Apache%202.0-green.svg)](LICENSE)

> **Status:** experimental, pre-1.0, Apple-only. JLISwift is a pure-Swift JPEG codec (Accelerate-backed DSP) that encodes and decodes **baseline (SOF0)**, **extended-sequential (SOF1, 12-bit)**, **progressive (SOF2, with restart markers)**, and **lossless (SOF3, predictive — incl. near-lossless)** JPEG at **8/12/16-bit**, plus **reduced-scale decode** (1/2, 1/4, 1/8). Quality tooling: **optimized per-image Huffman tables**, **trellis (rate-distortion) quantization**, **jpegli/JPEG-XL distance**, opt-in **jpegli perceptual quant tables** and a **spatial adaptive-quant field**, and **ICC / Exif** preservation. **XYB** color is implemented (experimental — see caveats below). It targets feature parity with Google's [jpegli](https://github.com/google/jpegli); the main thing left unwired is the **Metal** hot path. See [What's actually implemented](#whats-actually-implemented) for the full matrix.

## Quick start

```swift
dependencies: [
    .package(url: "https://github.com/raster-labs/JLISwift.git", from: "0.6.0"),
]
```

```swift
import JLISwift

// Encode
let image = try JLIImage(
    width: 256, height: 256,
    pixelFormat: .uint8, colorModel: .rgb,
    data: rgbBytes
)
let jpegData = try JLIEncoder().encode(image, configuration: .default)

// Decode
let decoded = try JLIDecoder().decode(from: jpegData)

// Metadata-only parse (skips entropy decode)
let info = try JLIDecoder().inspect(data: jpegData)
print(info.width, info.height, info.componentCount, info.chromaSubsampling)
```

## Caller-owned decode storage

Applications that admit their own buffers can use the synchronous borrowed APIs:

- `inspectBaselineRGBCore` / `decodeBaselineRGBCore`: sequential 8-bit, three-component JPEG to RGB8, including the existing source-color interpretation and chroma sampling rules.
- `inspectLosslessMonochromeCore` / `decodeLosslessMonochromeCore`: monochrome SOF3 at its declared precision, reconstructed directly as unsigned little-endian UInt16 samples.

Inspect baseline input with `JLIDecoder.baselineHeaderWorkspaceByteCount` bytes of header storage. The returned `BaselineRGBInfo` specifies the complete workspace and arena sizes. The arena retains **12 bytes per source pixel** after its first **3 bytes per pixel** are compacted to RGB8; account for the full retained arena capacity. The lossless workspace size is `JLIDecoder.losslessMonochromeWorkspaceByteCount`; its result describes the required output size. These APIs reuse the canonical parser, Huffman, prediction, IDCT and color kernels.

All supplied spans must remain alive until return. Input, output/arena and workspace must be disjoint; workspace and baseline arena require `Int` alignment and exclusive raw storage. The library borrows them without taking ownership. A failure or cancellation may leave partial pixels, so publish output only after success. Metadata payloads are not returned by these pixel-only APIs.

Core APIs return `JLICoreOutcome<Value>` with `.success(Value)` or `.failure(JLICoreFailure)`. The failure contains only `kind`, `code`, and three integer details; the qualified path does not invoke Swift error witnesses or throw hooks. `JLICancellation` accepts a synchronous C function pointer and a borrowed context, allowing the application to check its own cancellation flag without a captured closure. Its callback must be thread-safe and allocation-free, and its context must remain alive until return. The default is `.never`; cancellation takes effect at parser, row and tile checkpoints. The original APIs retain their existing `JLIError`/task-cancellation compatibility behavior.

Reported capacities cover the explicit parser, control and numerical storage. Applications must also qualify their caller, runtime and compiled execution profile when enforcing a complete process allocation contract.

## What's actually implemented

| Capability | Status |
|---|---|
| Baseline sequential JPEG (SOF0) encode | ✅ |
| Baseline sequential JPEG (SOF0) decode | ✅ |
| Chroma subsampling: 4:4:4, 4:2:2, 4:2:0, 4:0:0 (grayscale) | ✅ |
| Standard ITU-T T.81 Annex K Huffman tables | ✅ |
| **Optimized (per-image) Huffman tables** (Annex K.2, `optimiseHuffman`, default on) | ✅ |
| Restart markers (DRI / RST) — decode **and** encode (baseline + progressive, `restartInterval`) | ✅ |
| Quality-scaled standard quantization tables (IJG formula) | ✅ |
| Distance parameter (jpegli/JXL convention; maps to IJG quality) | ✅ |
| RGB / RGBA / grayscale / pre-converted YCbCr input (8-bit) | ✅ |
| **12-bit grayscale** encode + decode (`.uint16` → SOF1 precision-12 JPEG) | ✅ |
| **12-bit color** encode + decode (`.uint16` RGB ↔ SOF1 precision-12 YCbCr) | ✅ |
| SOF1 (extended sequential) decode — reads 12-bit JPEGs from libjpeg/ImageIO | ✅ |
| **Progressive (SOF2) decode** — multi-scan, spectral selection, successive approximation | ✅ |
| **Progressive (SOF2) encode** — spectral-selection *and* successive-approximation scan scripts (`progressive` + `progressiveMode`, opt-in) | ✅ |
| **Lossless (SOF3, predictive)** encode + decode — 8/12/16-bit, grayscale + RGB, predictors 1–7 | ✅ |
| **Near-lossless** via point transform (`losslessPointTransform`, bounded error 2^Pt−1) | ✅ |
| **Reduced-scale decode** — 1/2, 1/4, 1/8 (exact box averages from low-frequency coefficients, `scale`) | ✅ |
| `inspect()` — metadata parse without full decode | ✅ |
| Accelerate forward DCT/quantization, shared SIMD inverse DCT and BT.601 color conversion | ✅ |
| Round-trip + cross-codec tested (ImageIO, libjpeg-turbo, mozjpeg) on synthetic + DICOM | ✅ |
| Trellis quantization — keep/drop + HF magnitude reduction (`adaptiveQuantization`, 8-bit, default on) | ✅ |
| **jpegli perceptual quant tables** — libjxl base matrices + non-linear distance scale (`perceptualQuantTables`, opt-in) | ✅ |
| **Spatial adaptive-quant field** — per-block λ from a masking proxy (`adaptiveQuantField`, opt-in) | ✅ |
| **ICC profile + Exif** — extracted on decode, embedded on encode (`JLIImage.iccProfile` / `.exif`) | ✅ |
| **16-bit input** (lossless `.uint16`) · **float32 input** (normalised [0,1] → 8-bit) | ✅ |
| **XYB color space JPEG** — encode + decode + ICC; experimental (see caveats) | ✅ |
| Metal GPU pipeline | ⚠️ kernels compile but are not wired into encode/decode |

### Optimized Huffman tables

With `optimiseHuffman` (on by default) the encoder runs a counting pass over the
quantized coefficients, builds per-image DC/AC tables via the ITU-T T.81 Annex K.2
procedure, and embeds them in the DHT markers. Output stays fully baseline-compatible.

On the DICOM corpus this matches libjpeg-turbo's `-optimize` byte-for-byte to within
~0.5% at identical PSNR — a 21–54% size reduction over the fixed Annex K tables:

| Image @ q=50 | fixed tables | optimized | libjpeg-turbo `-optimize` |
|---|---|---|---|
| CT  | 5190 B | **2368 B** | 2383 B |
| MR  | 22982 B | **16541 B** | 16581 B |
| XA  | 35001 B | **27571 B** | 27719 B |

### Trellis quantization

With `adaptiveQuantization` (default on, 8-bit only) the encoder runs a Viterbi
rate-distortion pass per block, minimizing `D + λ·R` — DCT-domain squared error
(= pixel² by Parseval) against run-length-coded bits, λ ∝ mean AC quant step² so
truncation stays gentle at high quality. For each nonzero AC coefficient the DP
chooses to **drop** it (→0), **reduce** its magnitude one step (q→q∓1), or keep
it:

- dropping *interior* coefficients (an isolated nonzero costing a ZRL + symbol
  but barely reducing distortion) merges the surrounding zero runs;
- magnitude reduction trims a coefficient's size category + magnitude bits,
  restricted to higher frequencies (zigzag ≥ 6) — reducing the lowest AC
  frequencies costs visible quality for negligible rate;
- the EOB position falls out as "which kept coefficient is last."

Magnitudes are only reduced, never grown, so output stays standard baseline
JPEG. The rate model uses fixed Annex K table lengths, sidestepping the
chicken-and-egg with optimized Huffman (built afterward on the result).

On the DICOM corpus it trims 0.3–14.5% with butteraugli flat or better
(validated via `--butteraugli`) — keep/drop does most of that on smooth scans;
magnitude reduction adds a further ~0.1–0.5% and contributes more on
mid-magnitude (photographic) content. 12-bit stays exact round-to-nearest
(medical precision is not traded for bytes). High-entropy blocks (>32 nonzero AC
coeffs) skip the O(m²) DP, bounding worst-case encode time.
`optimiseHuffman`, `adaptiveQuantization` (trellis), `distance`, and `progressive`
are all honored. Two opt-in perceptual levers go further: `perceptualQuantTables`
derives the quant tables from jpegli's base matrices + non-linear distance scale
(rather than scaling Annex K), and `adaptiveQuantField` varies the trellis λ per
luma block by a masking proxy (~5–8% lower butteraugli on detailed 4:4:4 content;
off by default because it can slightly enlarge low-quality 4:2:0).

On the DICOM corpus, **spectral-selection** progressive 4:4:4 is ~5% smaller
than baseline 4:4:4 at identical PSNR — the AC-scan EOBRUN codes the long runs
of DC-only blocks in flat medical regions more compactly than baseline's
per-block EOB. **Successive-approximation** progressive (opt in via
`progressiveMode = .successiveApproximation`) is only ~2% on the same corpus:
its extra scans fragment those EOB runs, so it pulls ahead only on textured /
photographic content where the finer multi-pass refinement pays off. Both are
validated on the bench against ImageIO / libjpeg-turbo / mozjpeg, which all
decode JLISwift's progressive output.

## Encoder configuration

```swift
var config = JLIEncoderConfiguration.default
config.quality = 85.0                  // 1–100, IJG-compatible scaling
config.chromaSubsampling = .yuv444     // .yuv444, .yuv422, .yuv420, .yuv400

// Or drive quality by jpegli/JPEG-XL distance (overrides quality when set).
// ~1.0 is visually lossless; larger compresses harder.
config.distance = 1.0

// Opt into progressive (SOF2) output — DC then per-component AC scans.
config.progressive = true
```

`distance` maps to an effective IJG quality (libjxl's `JpegQualityToDistance`
curve, inverted) that scales the standard quant tables — same monotonic
rate/distance behavior as jpegli. For jpegli's actual perceptual rate
allocation, set `perceptualQuantTables = true`, which builds the tables from
libjxl's XYB base matrices and a per-coefficient non-linear distance function.

### XYB color (experimental)

`colorSpace = .xyb` encodes in JPEG XL's XYB perceptual color space (4:4:4) and
embeds an ICC profile (a faithful port of libjxl's XYB profile) so the result is
a standard JPEG. The color is provably correct — Apple's CoreGraphics transforms
the embedded profile to sRGB matching the codec's own inverse to **0.28/255**.
Two caveats keep it experimental:

- **Apple's image-render path** (Preview, `CGContext` drawing, `sips`) does **not**
  apply CLUT-based A2B ICC profiles, so it misrenders XYB JPEGs despite the
  profile being correct — on Apple, decode them with **this** library
  (`JLIDecoder` detects the profile and inverts XYB); browsers / libjxl-based
  CMS render them correctly.
- In current tuning the size/quality is ≈ at parity with the tuned YCbCr 4:4:4
  perceptual path, not a clear win — so the default stays YCbCr.

## Platform support

| Platform | Acceleration |
|---|---|
| macOS 14+ | Accelerate (vDSP/vImage), Metal* |
| iOS 17+ | Accelerate, Metal* |
| tvOS 17+ | Accelerate, Metal* |
| watchOS 10+ | Accelerate |
| visionOS 1+ | Accelerate, Metal* |

\* Metal compute pipeline (`JLIMetalPipeline`) exists but is not currently invoked from the encode/decode hot path.

Universal Binary supported — `swift build` produces fat output with `#if arch(arm64)` / `#if arch(x86_64)` selection.

## Performance

Numbers from `swift run -c release JLIBench` on Apple Silicon (M-series), median of 5 runs, synthetic 512×512 inputs:

| Test | JLISwift (4:4:4, q=90) | Apple ImageIO (q=90) |
|---|---|---|
| gradient — encode | 9.7 ms | 1.0 ms |
| gradient — decode | 14.4 ms | 0.9 ms |
| noise — encode | 24.9 ms | 3.3 ms |
| noise — decode | 33.0 ms | 2.7 ms |

(Numbers from an earlier run; encode has since gained a batched-accumulator
`BitWriter` and multi-threaded trellis + Huffman-counting.) ImageIO (C + hand-asm
libjpeg-turbo) is still several × faster. The forward/inverse DCT already runs as
a batched GEMM on Accelerate, so the gap is *cumulative* — spread across the DCT,
trellis, the optimized-Huffman counting pass, color conversion, and per-bit
entropy coding — rather than one fixable hotspot. Compression ratios are within a
few percent of ImageIO at matched quality.

Run the benchmark yourself:

```
swift run -c release JLIBench
```

## Architecture

```
Sources/JLISwift/
├── Core/                 JLIImage, JLIError, JLIConfiguration, JLIJPEGInfo
├── Encoder/              JLIEncoder (SOF0/SOF1/SOF2/SOF3 + XYB encode) + JLIProgressiveEncoder
├── Decoder/              JLIDecoder (SOF0/SOF1/SOF2/SOF3 decode, scaled decode, inspect()) + JLIProgressiveDecoder
├── DSP/                  JLIDCT (Accelerate façade), JLIQuantization
├── Entropy/              BitWriter/BitReader (incl. JPEG byte stuffing), Huffman tables + encode/decode
├── Markers/              SOI/APP0/SOF0/DHT/DQT/SOS/EOI writer + parser
├── ColorSpace/           BT.601 RGB↔YCbCr (vDSP-vectorized), XYB transforms, chroma sub/upsampling
├── Metal/                JLIMetalPipeline — compiles MSL kernels at runtime (not yet wired)
└── Platform/             AccelerateBackend (vDSP DSP primitives), JLIPlatformCapabilities

Sources/JLIBench/
├── Codecs/               Codec protocol, JLISwift adapter, ImageIO adapter,
│                         CLICodec shell-out base + reference adapters
│                         (libjpeg-turbo / mozjpeg / jpegli), PPM IO
├── Dataset/              DICOMReader (uncompressed VR LE), DICOMCorpus loader+cache
├── Regression/           Save/load JSON baseline, diff with tolerances, exit 1 on drift
├── Harness.swift         Median-of-N timing, PSNR, self/cross runners
└── main.swift            CLI: synthetic + DICOM modes, regression flags

Tests/JLISwiftTests/      160 tests across 16 suites (Swift Testing framework)
```

## Bench: cross-codec + regression

The `JLIBench` target benchmarks JLISwift against system codecs and tracks
regressions across runs.

```bash
swift run -c release JLIBench                           # synthetic corpus
swift run -c release JLIBench --dicom                   # + DICOM corpus
swift run -c release JLIBench --save-baseline b.json    # snapshot
swift run -c release JLIBench --check-baseline b.json   # exit 1 on regression
```

### Reference codecs (auto-detected)

The bench probes for these external encoders and includes any that are
installed. Cross-codec pairs are generated automatically: `JLISwift →
each-reference` and `each-reference → JLISwift`.

| Codec | Install | Probed path |
|---|---|---|
| **libjpeg-turbo** | `brew install jpeg-turbo` | `/opt/homebrew/opt/jpeg-turbo/bin/{cjpeg,djpeg}` |
| **mozjpeg** | `brew install mozjpeg` | `/opt/homebrew/opt/mozjpeg/bin/{cjpeg,djpeg}` |
| **jpegli** | `brew install jpegli` or build libjxl with `JPEGXL_ENABLE_TOOLS=ON` | `/opt/homebrew/opt/jpegli/bin/cjpegli` |

The bench prints active vs inactive codecs at startup. Per-codec binary
paths can also be overridden via env vars (`JLIBENCH_LIBJPEG_TURBO_BIN`,
`JLIBENCH_MOZJPEG_BIN`, `JLIBENCH_JPEGLI_BIN`).

External codecs spawn a process per encode/decode (~70 ms overhead each on
macOS) so the harness times them with a single sample rather than the
median-of-5 it uses for native codecs. Bytes and PSNR are unaffected.

### Perceptual metric (butteraugli)

`--butteraugli` adds a butteraugli perceptual-distance column to self-codec
rows (lower is better; ~1.0 = just-noticeable-difference). It shells out to
libjxl's `butteraugli_main` (Homebrew `jpeg-xl`), comparing the original and
round-tripped images. This is the right metric for perceptually-tuned
techniques — PSNR can't see them. Slow (a process per row), so it's opt-in.

### DICOM corpus

`JLIBench --dicom` loads a small sample from a clinical DICOM tree
(`Sources/LocalDatasets/medical-dicom-organized/` by default), windows the
16-bit pixels to 8-bit, and runs every codec + cross pair against the
result. Files that hit unsupported transfer syntaxes (compressed-in-DICOM,
RLE) are silently skipped — only uncompressed Little Endian VR (Implicit
and Explicit, the typical CT/MR/DX/MG output) is decoded today. Converted
images are cached at `~/.cache/jlibench/corpus/`; `--rebuild-cache` clears
it.

`--dicom12` runs the corpus at **native 12-bit precision** instead of
window/leveling to 8-bit: each image is rendered to 12-bit grayscale
(0–4095) and round-tripped through JLISwift and libjpeg-turbo's 12-bit
mode (`cjpeg -precision 12`), with PSNR measured against the 4095 peak.
This is the medically-relevant path — it preserves the tonal resolution
8-bit discards. On the corpus JLISwift matches libjpeg-turbo-12 within
~0.1% bytes at 67–83 dB PSNR (vs 44–59 dB for the 8-bit path), and
JLISwift ↔ libjpeg-turbo-12 cross-decode passes both directions.

## Roadmap

JLISwift's direction is feature parity with [jpegli](https://github.com/google/jpegli), Google's improved JPEG encoder. The 0.1.x line already covers the bulk of it: baseline / extended-sequential (12-bit) / progressive / lossless JPEG, optimized Huffman, trellis quantization, distance, jpegli perceptual quant tables and a spatial adaptive-quant field, and XYB color (experimental). A measured finding from this work: most of jpegli's quality gain comes from the perceptual quantization (which the YCbCr path now has) rather than the XYB color space — in testing, XYB lands ≈ at parity with the YCbCr perceptual path.

Remaining (deferred — low/uncertain value or out of scope for now):

1. **Metal hot path** — actually invoke the existing `JLIMetalPipeline` kernels; marginal over the Accelerate AMX/GPU GEMM, and hard to validate bit-exactly.

Done since 0.1 — all cross-validated against libjpeg-turbo / mozjpeg / ImageIO (and Apple CoreGraphics for XYB color) with PSNR + butteraugli, regression-tracked: spec fixes (byte-unstuffing, DRI/RST, SOF1); Accelerate-backed batched DCT; **optimized Huffman tables**; **table-driven (8-bit lookahead) Huffman decode** (~15–19% faster decode on entropy-heavy content, bit-identical, bit-by-bit fallback at markers/long codes); **12/16-bit** and **float32** input; **distance parameter**; **trellis quantization**; **jpegli perceptual quant tables** + **spatial adaptive-quant field**; **progressive (SOF2)** decode + encode **with restart markers**; **lossless (SOF3)** + **near-lossless**; **reduced-scale decode** (1/2, 1/4, 1/8); **ICC / Exif** metadata; **XYB** color encode/decode (experimental); **multi-threaded** trellis + Huffman-counting encode; and **fuzz-hardened decoding** (throws, never traps).

## Requirements

- Swift 6.2+ (strict concurrency)
- Xcode 26+ for Apple platforms

## License

Apache License 2.0 — see [LICENSE](LICENSE).

## Acknowledgements

- [Google jpegli](https://github.com/google/jpegli) — the reference JPEG encoder JLISwift aspires to.
- [libjxl](https://github.com/libjxl/libjxl) — host of jpegli, source of the XYB color space and butteraugli metric.
- [libjpeg-turbo](https://github.com/libjpeg-turbo/libjpeg-turbo) — baseline JPEG reference for benchmarking.
