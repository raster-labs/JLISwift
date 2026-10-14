// SPDX-License-Identifier: Apache-2.0
import Foundation
/// Fixed-value failure from the controlled decoder. Descriptions and legacy
/// error boxes are constructed only by compatibility APIs, never by core calls.
public struct JLICoreFailure: Error, Sendable, Equatable {
    public enum Kind: UInt8, Sendable, Equatable { case cancelled, invalidJPEG, decoding, unsupported }
    public let code: UInt16
    public let kind: Kind
    public let detail0: Int, detail1: Int, detail2: Int
    internal init(code: UInt16, kind: Kind, detail0: Int = 0, detail1: Int = 0, detail2: Int = 0) {
        self.code = code; self.kind = kind; self.detail0 = detail0; self.detail1 = detail1; self.detail2 = detail2
    }
    internal var compatibilityError: any Error {
        if kind == .cancelled { return CancellationError() }
        if kind == .invalidJPEG { return JLIError.invalidJPEGData }
        let message: String
        switch code {
        case 100: message = "The input data is not a valid JPEG bitstream"
        case 101: message = "Multiple SOF markers"
        case 102: message = "Invalid DRI length"
        case 103: message = "Too many caller-storage scans"
        case 104: message = "Trailing bytes or concatenated JPEG codestream"
        case 105: message = "Missing JPEG EOI marker"
        case 106: message = "The input data is not a valid JPEG bitstream"
        case 107: message = "Invalid or truncated JPEG segment length"
        case 108: message = "The input data is not a valid JPEG bitstream"
        case 109: message = "Invalid segment length"
        case 110: message = "Invalid segment length"
        case 111: message = "Unsupported caller-storage component count"
        case 112: message = "Invalid SOF length"
        case 113: message = "invalid DQT precision \(detail0)"
        case 114: message = "invalid DQT table id \(detail0)"
        case 115: message = "Truncated DQT segment"
        case 116: message = "Truncated DHT counts"
        case 117: message = "invalid DHT: Huffman code oversubscribed at length \(detail0)"
        case 118: message = "invalid DHT: \(detail0) codes (max 256)"
        case 119: message = "Truncated DHT values"
        case 120: message = "Unsupported caller-storage component count"
        case 121: message = "Invalid SOS length"
        case 122: message = "Unexpected end of JPEG data"
        case 123: message = "invalid bit-read width \(detail0)"
        case 124: message = "Unexpected end of entropy-coded data"
        case 125: message = "Unexpected end of data after 0xFF"
        case 126: message = "Unexpected marker 0xFF\(String(format: "%02X", detail0)) in entropy data"
        case 127: message = "Unexpected end of data expecting RST marker"
        case 128: message = "Expected RST marker at offset \(detail0), got 0x\(String(format: "%02X", detail1))"
        case 129: message = "Expected RST\(detail0) (0xFF D\(detail1)), got 0xFF \(String(format: "%02X", detail2))"
        case 130: message = "Huffman code index out of range"
        case 131: message = "Invalid Huffman code"
        case 132: message = "Invalid Huffman value category"
        case 133: message = "Caller-storage lossless decoding requires a monochrome SOF3 frame"
        case 134: message = "Caller-storage RGB requires sequential 8-bit JPEG"
        case 135: message = "Repeated or unknown sequential scan component"
        case 136: message = "Invalid quantization table selector"
        case 137: message = "Incomplete sequential component scans"
        case 138: message = "lossless precision \(detail0)"
        case 139: message = "float32 output for lossless (use the bit-exact .uint8/.uint16 output)"
        case 140: message = "invalid lossless dimensions \(detail0)×\(detail1)"
        case 141: message = "lossless image too large: \(detail0)×\(detail1) exceeds \(detail2)-pixel limit"
        case 142: message = "lossless \(detail0)-component (only 1 or 3)"
        case 143: message = "subsampled lossless"
        case 144: message = "Noninterleaved lossless JPEG scans"
        case 145: message = "invalid lossless predictor \(detail0)"
        case 146: message = "invalid lossless point transform \(detail0) for precision \(detail1)"
        case 147: message = "sample precision \(detail0) (only 8 and 12 supported)"
        case 148: message = "invalid image dimensions \(detail0)×\(detail1)"
        case 149: message = "image too large: \(detail0)×\(detail1) exceeds \(detail2)-pixel limit"
        case 150: message = "\(detail0)-component JPEG (only 1 or 3 supported)"
        case 151: message = "invalid sampling factor for component \(detail0)"
        case 152: message = "component \(detail0) references undefined quant table \(detail1)"
        case 153: message = "Invalid RGB arena alignment or overlapping spans"
        case 154: message = "Insufficient RGB arena/workspace capacity"
        case 155: message = "Unknown scan component"
        case 156: message = "DC coefficient overflow"
        case 157: message = "Caller-storage sequential decoding requires full-resolution RGB8"
        case 158: message = "RGB size exceeds limits"
        case 159: message = "Invalid RGB input/header workspace"
        case 160: message = "Unsupported JPEG source color interpretation"
        case 161: message = "Caller input, output and workspace overlap"
        case 162: message = "Lossless output capacity is too small"
        case 163: message = "Lossless restart interval is not a multiple of samples per row"
        case 164: message = "Caller-storage decoding requires monochrome SOF3"
        case 165: message = "Caller-storage output is always little-endian UInt16"
        case 166: message = "Lossless frame exceeds pixel/byte limit"
        case 167: message = "Monochrome output requires grayscale interpretation"
        case 168: message = "Invalid caller input or workspace capacity/alignment"
        case 169: message = "Unsupported JPEG source color interpretation"
        default: message = "JPEG core failure \(code)"
        }
        return kind == .unsupported ? JLIError.unsupportedJPEGFeature(message) : JLIError.decodingFailed(message)
    }
}
/// Fixed value transport for the caller-owned core. Failure handling does not
/// invoke Swift error witnesses, error boxing, or debugger throw hooks.
public enum JLICoreOutcome<Value> {
    case success(Value)
    case failure(JLICoreFailure)

    internal var failureValue: JLICoreFailure {
        switch self {
        case .failure(let failure): return failure
        case .success: preconditionFailure("Expected an already-checked failure")
        }
    }
}

internal func jliCompatibility<Value>(_ body: () -> JLICoreOutcome<Value>) throws -> Value {
    switch body() {
    case .success(let value): return value
    case .failure(let failure): throw failure.compatibilityError
    }
}
