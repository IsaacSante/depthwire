import Accelerate
import CoreGraphics
import CoreVideo
import Foundation

/// Turns millimeter depth into the camera's final 16:9 BGRA frame.
/// Not thread-safe: use from one queue.
final class DepthRenderer {
    enum Palette: String, CaseIterable, Identifiable {
        case turbo = "Rainbow"
        case grayscale = "Grayscale"
        var id: Self { self }
    }

    enum Framing: String, CaseIterable, Identifiable {
        case fit = "Fit"   // whole depth image, black bars
        case fill = "Fill" // fills the frame, crops the edges
        var id: Self { self }
    }

    var nearMeters: Float = 0.2
    var farMeters: Float = 5.0
    var framing: Framing = .fit
    /// With player labels: tint each player its own color instead of the depth palette.
    var playerColors = false
    var palette: Palette = .turbo {
        didSet { lut = Self.makeLUT(palette) }
    }

    private var lut = DepthRenderer.makeLUT(.turbo)
    private var small = [UInt8]()
    private var pool: CVPixelBufferPool?

    init() {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(CameraConstants.output.width),
            kCVPixelBufferHeightKey as String: Int(CameraConstants.output.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    }

    /// Returns the final camera frame and, if asked, a CGImage of that same frame.
    /// `labels`, when given, is one byte per depth pixel: 0 = background (drawn black),
    /// 1… = player index.
    func render(millimeters: Data, labels: [UInt8]?, width: Int, height: Int, makePreview: Bool) -> (CVPixelBuffer?, CGImage?) {
        colorize(millimeters, labels: labels, width: width, height: height)

        var output: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) }
        guard let output else { return (nil, nil) }

        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }

        let base = CVPixelBufferGetBaseAddress(output)!
        let rowBytes = CVPixelBufferGetBytesPerRow(output)
        let outWidth = CVPixelBufferGetWidth(output), outHeight = CVPixelBufferGetHeight(output)
        var whole = vImage_Buffer(data: base, height: vImagePixelCount(outHeight),
                                  width: vImagePixelCount(outWidth), rowBytes: rowBytes)
        vImageBufferFill_ARGB8888(&whole, [0, 0, 0, 255], vImage_Flags(kvImageNoFlags))

        small.withUnsafeMutableBytes { smallBytes in
            let fitScale = min(Double(outWidth) / Double(width), Double(outHeight) / Double(height))
            let fillScale = max(Double(outWidth) / Double(width), Double(outHeight) / Double(height))
            var src: vImage_Buffer
            var dst: vImage_Buffer
            switch framing {
            case .fit:
                // Whole source into a centered sub-rect of the output.
                let w = Int(Double(width) * fitScale), h = Int(Double(height) * fitScale)
                let x = (outWidth - w) / 2, y = (outHeight - h) / 2
                src = vImage_Buffer(data: smallBytes.baseAddress, height: vImagePixelCount(height),
                                    width: vImagePixelCount(width), rowBytes: width * 4)
                dst = vImage_Buffer(data: base + y * rowBytes + x * 4, height: vImagePixelCount(h),
                                    width: vImagePixelCount(w), rowBytes: rowBytes)
            case .fill:
                // Centered crop of the source into the whole output.
                let w = min(width, Int((Double(outWidth) / fillScale).rounded()))
                let h = min(height, Int((Double(outHeight) / fillScale).rounded()))
                let x = (width - w) / 2, y = (height - h) / 2
                src = vImage_Buffer(data: smallBytes.baseAddress! + (y * width + x) * 4, height: vImagePixelCount(h),
                                    width: vImagePixelCount(w), rowBytes: width * 4)
                dst = whole
            }
            vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
        }

        var preview: CGImage?
        if makePreview {
            let data = Data(bytes: base, count: rowBytes * outHeight)
            if let provider = CGDataProvider(data: data as CFData) {
                preview = CGImage(width: outWidth, height: outHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                      | CGImageAlphaInfo.noneSkipFirst.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            }
        }
        return (output, preview)
    }

    /// Fills `small` with BGRA colors at the depth map's own resolution.
    private func colorize(_ millimeters: Data, labels: [UInt8]?, width: Int, height: Int) {
        let count = width * height
        if small.count != count * 4 { small = [UInt8](repeating: 255, count: count * 4) }

        let near = nearMeters * 1000
        let far = max(farMeters * 1000, near + 1)
        let scale = Float(lut.count - 1) / (far - near)
        let tintPlayers = playerColors && labels != nil

        millimeters.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: UInt16.self)
            small.withUnsafeMutableBufferPointer { dst in
                lut.withUnsafeBufferPointer { lut in
                    for i in 0..<count {
                        let mm = Float(UInt16(littleEndian: src[i]))
                        let color: UInt32
                        let player = labels?[i] ?? 0
                        if mm == 0 || (labels != nil && player == 0) {
                            color = 0xFF00_0000 // no reading or background: black
                        } else if tintPlayers {
                            // Player hue, brighter when nearer.
                            let nearness = (far - min(max(mm, near), far)) / (far - near)
                            color = Self.shade(Self.playerPalette[Int(player - 1) % Self.playerPalette.count],
                                               by: 0.35 + 0.65 * nearness)
                        } else {
                            // Near maps to the top of the palette (red / white).
                            let t = Int(((far - min(max(mm, near), far)) * scale).rounded())
                            color = lut[t]
                        }
                        dst[i * 4 + 0] = UInt8(color & 0xFF)         // B
                        dst[i * 4 + 1] = UInt8((color >> 8) & 0xFF)  // G
                        dst[i * 4 + 2] = UInt8((color >> 16) & 0xFF) // R
                        dst[i * 4 + 3] = 255                         // A
                    }
                }
            }
        }
    }

    /// Distinct 0xRRGGBB colors for players 1…6.
    private static let playerPalette: [UInt32] = [0x4FC3F7, 0xFFB74D, 0x81C784, 0xF06292, 0xBA68C8, 0xFFF176]

    private static func shade(_ rgb: UInt32, by factor: Float) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 { UInt32(Float((rgb >> shift) & 0xFF) * factor) << shift }
        return 0xFF00_0000 | channel(16) | channel(8) | channel(0)
    }

    /// 1024-entry 0xAARRGGBB lookup table, index 0 = far, last = near.
    private static func makeLUT(_ palette: Palette) -> [UInt32] {
        (0..<1024).map { i in
            let x = Double(i) / 1023
            let (r, g, b): (Double, Double, Double)
            switch palette {
            case .grayscale:
                (r, g, b) = (x, x, x)
            case .turbo:
                // Google's polynomial approximation of the Turbo colormap; x = 1 is red.
                r = 0.13572138 + x * (4.61539260 + x * (-42.66032258 + x * (132.13108234 + x * (-152.94239396 + x * 59.28637943))))
                g = 0.09140261 + x * (2.19418839 + x * (4.84296658 + x * (-14.18503333 + x * (4.27729857 + x * 2.82956604))))
                b = 0.10667330 + x * (12.64194608 + x * (-60.58204836 + x * (110.36276771 + x * (-89.90310912 + x * 27.34824973))))
            }
            func byte(_ v: Double) -> UInt32 { UInt32(max(0, min(1, v)) * 255) }
            return 0xFF00_0000 | byte(r) << 16 | byte(g) << 8 | byte(b)
        }
    }
}
