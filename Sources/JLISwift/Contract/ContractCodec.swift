// SPDX-License-Identifier: MIT
//
// The shared-contract codec surface for jpegli.
//
// This is the contract's `Image` layer wired to the existing lossless JPEG
// codec. It sits beside the library's established `JLIEncoder`/`JLIDecoder`
// API rather than replacing it: decision D1 keeps the codec in this
// repository, so both surfaces coexist and the established one keeps its
// consumers.
//
// The initial shared layout (MEM-03) is what this surface guarantees today:
// one plane, one component, unsigned 16-bit, little-endian, even
// `rowBytes >= width * 2`, no subsampling, lossless SOF3. Anything else is
// reported as an incompatibility rather than silently converted.

import Foundation

public struct JLIContractCodec: Sendable {
    public init() {}

    /// What this surface can actually do, as opposed to what the contract
    /// describes. POL-08: planned capability is not reported as present.
    public static var capabilities: CodecCapabilities {
        CodecCapabilities(
            formats: ["JPEG (lossless, SOF3)"],
            compressionModes: [.lossless],
            sampleTypes: [.unsignedInteger],
            meaningfulPrecision: 2...16,
            layouts: ["greyscale16"],
            availableBackends: [.scalarCPU],
            canInspect: true, canEncode: true, canDecode: true)
    }

    /// The configuration the shared surface encodes with. Fixed rather than
    /// caller-supplied so the layout guarantee cannot be undermined by, say,
    /// a non-zero point transform.
    ///
    /// `losslessPrecision` is stated explicitly. Left at its default of zero
    /// the encoder derives precision from the pixel format, and `.uint16`
    /// derives **12** bits — a DCT-oriented default that also governs the
    /// lossless path. A descriptor's `meaningfulBits` is the authority here,
    /// so it is passed through rather than inferred.
    static func losslessConfiguration(precision: Int) -> JLIEncoderConfiguration {
        var cfg = JLIEncoderConfiguration.diagnosticLossless
        cfg.losslessPointTransform = 0
        cfg.losslessPrecision = precision
        return cfg
    }

    // MARK: - Inspection

    /// Describe the output layout a decode would produce, without decoding
    /// (MEM-10).
    public func inspect(_ data: [UInt8], limits: ResourceLimits = .default) throws -> ImageDescriptor {
        let info = try Self.info(data, limits: limits)
        return try ImageDescriptor.greyscale16(
            width: info.width, height: info.height,
            meaningfulBits: info.bitsPerComponent, limits: limits)
    }

    // MARK: - Encode

    /// Encode an `Image` whose samples stay where the caller put them.
    public func encode(_ image: Image,
                       configuration: EncoderConfiguration = .default,
                       options: EncodeOptions = EncodeOptions()) throws -> ([UInt8], OperationReport) {
        let started = Date()
        guard configuration.mode == .lossless else {
            throw CodecError(.unsupportedFeature, "This surface encodes the lossless mode only.")
        }
        let layout = try SharedLayout(descriptor: image.descriptor, policy: options.copyPolicy)
        try image.descriptor.validate(limits: options.resourceLimits)

        let bytes: [UInt8] = try image.storage.withUnsafeBytes { raw in
            try layout.checkCapacity(raw.count)
            try Task.checkCancellation()
            // The borrow exists only inside this closure, so the pointer
            // cannot outlive the caller's storage (MEM-08).
            let region = UnsafeRawBufferPointer(
                rebasing: raw[layout.offset..<(layout.offset + layout.extent)])
            let plane = BorrowedSamplePlane(bytes: region, rowBytes: layout.rowBytes)
            do {
                return try JLIEncoder().encodeLosslessGreyscale(
                    from: plane, width: layout.width, height: layout.height,
                    precision: layout.meaningfulBits,
                    configuration: Self.losslessConfiguration(precision: layout.meaningfulBits))
            } catch let error as JLIError {
                throw CodecError(.internalFailure, "Lossless encode failed: \(error)")
            }
        }

        let report = OperationReport(
            backend: .scalarCPU, fidelity: .exactSamples,
            // No copy events: samples were read in place.
            copyEvents: [], pixelAllocationCount: 0, peakPixelBytes: 0,
            // The encoder's Int32 sample planes and residual buffer, which
            // MEM-10 permits and MEM-10 (0.6.0) requires stating: four bytes
            // per sample each, so eight per sample in total.
            peakWorkspaceBytes: try checkedMultiply(layout.sampleCount, 8),
            elapsedSeconds: Date().timeIntervalSince(started))
        return (bytes, report)
    }

    // MARK: - Decode

    /// Decode into the caller's destination, writing final samples straight
    /// into its allocation (MEM-10).
    @discardableResult
    public func decode(_ data: [UInt8], into destination: ImageDestination,
                       configuration: DecoderConfiguration = DecoderConfiguration(),
                       options: DecodeOptions = DecodeOptions()) throws -> (Image, OperationReport) {
        let started = Date()
        _ = configuration
        let layout = try SharedLayout(descriptor: destination.descriptor, policy: options.copyPolicy)
        let info = try Self.info(data, limits: options.resourceLimits)
        guard info.width == layout.width, info.height == layout.height else {
            throw CodecError(.incompatibleImageLayout,
                "Codestream is \(info.width)x\(info.height); destination is \(layout.width)x\(layout.height).")
        }
        guard info.bitsPerComponent == layout.meaningfulBits else {
            throw CodecError(.incompatibleImageLayout,
                "Codestream is \(info.bitsPerComponent)-bit; destination declares \(layout.meaningfulBits).")
        }

        var decoderConfiguration = JLIDecoderConfiguration.default
        decoderConfiguration.outputPixelFormat = .uint16
        decoderConfiguration.outputColorModel = .grayscale

        // One exclusive write, sealed on success and invalidated on failure by
        // `ImageDestination.write`.
        let image = try destination.write { raw in
            try layout.checkCapacity(raw.count)
            try Task.checkCancellation()
            let region = UnsafeMutableRawBufferPointer(
                rebasing: raw[layout.offset..<(layout.offset + layout.extent)])
            let plane = BorrowedSampleDestination(bytes: region, rowBytes: layout.rowBytes)
            do {
                _ = try JLIDecoder().decodeLosslessGreyscale(
                    from: data, into: plane, configuration: decoderConfiguration)
            } catch let error as JLIError {
                throw CodecError(.malformedInput, "Lossless decode failed: \(error)")
            }
        }

        let report = OperationReport(
            backend: .scalarCPU, fidelity: .exactSamples, copyEvents: [],
            pixelAllocationCount: 0, peakPixelBytes: 0,
            // The decoder's Int32 sample plane: four bytes per sample.
            peakWorkspaceBytes: try checkedMultiply(layout.sampleCount, 4),
            elapsedSeconds: Date().timeIntervalSince(started))
        return (image, report)
    }

    /// Allocating convenience. MEM-10 requires this and the caller-destination
    /// decode to use the same final-output path, so it allocates a destination
    /// and calls the method above rather than having a path of its own.
    public func decode(_ data: [UInt8],
                       configuration: DecoderConfiguration = DecoderConfiguration(),
                       options: DecodeOptions = DecodeOptions()) throws -> (Image, OperationReport) {
        let descriptor = try inspect(data, limits: options.resourceLimits)
        let destination = try ImageDestination.allocate(
            descriptor: descriptor, limits: options.resourceLimits)
        return try decode(data, into: destination, configuration: configuration, options: options)
    }

    // MARK: - Inspection helper

    private static func info(_ data: [UInt8], limits: ResourceLimits) throws -> JLIJPEGInfo {
        guard data.count <= limits.maximumCompressedBytes else {
            throw CodecError(.resourceLimitExceeded, "Compressed input exceeds the operation budget.")
        }
        let info: JLIJPEGInfo
        do {
            info = try JLIDecoder().inspect(data: data)
        } catch let error as JLIError {
            throw CodecError(.malformedInput, "JPEG inspection failed: \(error)")
        }
        guard info.componentCount == 1 else {
            throw CodecError(.unsupportedFeature,
                "This surface handles one component; image has \(info.componentCount).")
        }
        guard info.bitsPerComponent > 8, info.bitsPerComponent <= 16 else {
            throw CodecError(.unsupportedFeature,
                "The shared layout is 16-bit storage; image is \(info.bitsPerComponent)-bit.")
        }
        return info
    }
}

// MARK: - Shared layout

/// The MEM-03 profile read off a descriptor, with MEM-04's checked arithmetic
/// resolved once so neither codec direction repeats it.
struct SharedLayout {
    let width: Int, height: Int, meaningfulBits: Int
    let offset: Int, rowBytes: Int, extent: Int, sampleCount: Int

    init(descriptor: ImageDescriptor, policy: CopyPolicy) throws {
        guard descriptor.planes.count == 1, descriptor.components.count == 1,
              descriptor.components.first == .grey, descriptor.colour == .greyscale,
              descriptor.alpha == .absent else {
            throw CodecError(.incompatibleImageLayout,
                "This surface requires the single-plane greyscale shared layout.")
        }
        guard descriptor.sampleType == .unsignedInteger, descriptor.storageBits == 16 else {
            throw CodecError(.incompatibleImageLayout, "The shared layout is unsigned 16-bit storage.")
        }
        guard descriptor.byteOrder == .littleEndian else {
            // Representable, but it is a copy, and under `requireSharedStorage`
            // a copy is the thing being excluded. Declining both ways is more
            // honest than differing by policy.
            throw CodecError(.incompatibleImageLayout,
                "The shared layout is little-endian; this descriptor is big-endian.")
        }
        let plane = descriptor.planes[0]
        guard plane.pixelStride == 2, plane.sampleStride == 2 else {
            throw CodecError(.incompatibleImageLayout,
                "The shared layout is a two-byte sample and pixel stride.")
        }
        guard plane.rowBytes % 2 == 0, plane.rowBytes >= descriptor.width * 2 else {
            throw CodecError(.incompatibleImageLayout, "rowBytes must be even and at least width * 2.")
        }
        guard plane.offset % 2 == 0 else {
            throw CodecError(.incompatibleImageLayout,
                "Plane offset must be two-byte aligned for 16-bit samples.")
        }
        // Every layout this surface accepts is already shareable, so the
        // default path never silently becomes a copy (MEM-12).
        _ = policy

        width = descriptor.width
        height = descriptor.height
        meaningfulBits = descriptor.meaningfulBits
        offset = plane.offset
        rowBytes = plane.rowBytes
        extent = try checkedAdd(checkedMultiply(descriptor.height - 1, plane.rowBytes),
                                checkedMultiply(descriptor.width, 2))
        sampleCount = try checkedMultiply(descriptor.width, descriptor.height)
    }

    /// MEM-04: the last byte touched, checked against the retained allocation.
    func checkCapacity(_ byteCount: Int) throws {
        let needed = try checkedAdd(offset, extent)
        guard byteCount >= needed else {
            throw CodecError(.storageUnavailable,
                "Storage holds \(byteCount) bytes; the layout needs \(needed).")
        }
    }
}
