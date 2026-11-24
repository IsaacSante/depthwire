import Compression
import Foundation

/// Wire format between the iPhone and the Mac.
///
/// Every frame is a 28-byte little-endian header followed by an LZ4-compressed
/// payload. All planes are `width * height`, row-major, rotated upright for how
/// the phone is held, and appear in this order:
///
/// 1. Depth: UInt16 millimeters (0 = no reading). Always present.
/// 2. Confidence: UInt8 ARKit confidence (0 low, 1 medium, 2 high), if `.confidence` is set.
/// 3. Person mask: UInt8 (255 = person), if `.personMask` is set.
/// 4. Camera: seven Float32s, if `.camera` is set. The lens (fx, fy, cx, cy) in pixels of
///    this rotated depth image, then which way is down (gravity, unit length) in its camera
///    space: x right, y up, z forward out of the lens. With these the Mac can place every
///    pixel in the room instead of guessing the field of view and tilt.
enum DepthWireProtocol {
    static let serviceType = "_depthwire._tcp"
    /// The phone always listens on this port too, so a Mac can reach it over the USB
    /// cable through usbmuxd (the tunnel Xcode uses), with no Wi-Fi in the way.
    static let usbPort: UInt16 = 52346
    static let magic: UInt32 = 0x4C44_5232 // "LDR2"
    static let headerSize = 28

    struct Flags: OptionSet {
        let rawValue: UInt32
        static let confidence = Flags(rawValue: 1 << 0)
        static let personMask = Flags(rawValue: 1 << 1)
        static let camera = Flags(rawValue: 1 << 2)
    }

    struct CameraInfo {
        var fx, fy, cx, cy: Float
        var gravity: SIMD3<Float>

        static let byteCount = 28

        init(fx: Float, fy: Float, cx: Float, cy: Float, gravity: SIMD3<Float>) {
            self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
            self.gravity = gravity
        }

        init?(_ data: Data) {
            guard data.count == Self.byteCount else { return nil }
            func float(_ i: Int) -> Float { Float(bitPattern: data.readLE(UInt32.self, at: i * 4)) }
            fx = float(0); fy = float(1); cx = float(2); cy = float(3)
            gravity = SIMD3(float(4), float(5), float(6))
        }

        func encoded() -> Data {
            var data = Data(capacity: Self.byteCount)
            for value in [fx, fy, cx, cy, gravity.x, gravity.y, gravity.z] { data.appendLE(value.bitPattern) }
            return data
        }
    }

    struct Header {
        var width: UInt16
        var height: UInt16
        var timestamp: Double
        var compressedLength: UInt32
        var rawLength: UInt32
        var flags: Flags

        init(width: UInt16, height: UInt16, timestamp: Double, compressedLength: UInt32, rawLength: UInt32, flags: Flags) {
            self.width = width
            self.height = height
            self.timestamp = timestamp
            self.compressedLength = compressedLength
            self.rawLength = rawLength
            self.flags = flags
        }

        init?(_ data: Data) {
            guard data.count == DepthWireProtocol.headerSize,
                  data.readLE(UInt32.self, at: 0) == DepthWireProtocol.magic else { return nil }
            width = data.readLE(UInt16.self, at: 4)
            height = data.readLE(UInt16.self, at: 6)
            timestamp = Double(bitPattern: data.readLE(UInt64.self, at: 8))
            compressedLength = data.readLE(UInt32.self, at: 16)
            rawLength = data.readLE(UInt32.self, at: 20)
            flags = Flags(rawValue: data.readLE(UInt32.self, at: 24))
        }

        func encoded() -> Data {
            var data = Data(capacity: DepthWireProtocol.headerSize)
            data.appendLE(DepthWireProtocol.magic)
            data.appendLE(width)
            data.appendLE(height)
            data.appendLE(timestamp.bitPattern)
            data.appendLE(compressedLength)
            data.appendLE(rawLength)
            data.appendLE(flags.rawValue)
            return data
        }

        /// Payload size these dimensions and flags imply, before compression.
        var expectedRawLength: Int {
            let pixels = Int(width) * Int(height)
            return pixels * 2
                + (flags.contains(.confidence) ? pixels : 0)
                + (flags.contains(.personMask) ? pixels : 0)
                + (flags.contains(.camera) ? CameraInfo.byteCount : 0)
        }
    }

    static func compress(_ raw: Data) -> Data? {
        let capacity = raw.count + 4096
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            raw.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                    nil, COMPRESSION_LZ4)
            }
        }
        guard written > 0 else { return nil }
        out.count = written
        return out
    }

    static func decompress(_ data: Data, rawLength: Int) -> Data? {
        var out = Data(count: rawLength)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, rawLength,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_LZ4)
            }
        }
        return written == rawLength ? out : nil
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value: T = 0
        let start = startIndex + offset
        _ = Swift.withUnsafeMutableBytes(of: &value) {
            copyBytes(to: $0, from: start..<(start + MemoryLayout<T>.size))
        }
        return T(littleEndian: value)
    }
}
