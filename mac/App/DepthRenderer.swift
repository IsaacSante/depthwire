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
    var framing: Framing = .fill
    /// Fill only: which frame-shaped part of the phone's picture is kept. Zoom 1 is the biggest
    /// part that fits, 2 half as wide; the shifts slide it across what's left, -1…1 (0 centred, +y down).
    var cropZoom: Float = 1
    var cropShiftX: Float = 0
    var cropShiftY: Float = 0
    /// Mirror the picture other apps get, left to right and/or top to bottom.
    var flipX = false
    var flipY = false
    /// The size of the picture other apps get; one of `CameraConstants.sizes`.
    var outputSize = (width: Int(CameraConstants.output.width), height: Int(CameraConstants.output.height)) {
        didSet { if oldValue != outputSize { makePool() } }
    }
    /// With player labels: tint each player its own color instead of the depth palette.
    var playerColors = false
    var palette: Palette = .turbo {
        didSet { lut = Self.makeLUT(palette) }
    }

    private var lut = DepthRenderer.makeLUT(.turbo)
    private var small = [UInt8]()
    private var pool: CVPixelBufferPool?

    init() { makePool() }

    private func makePool() {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputSize.width,
            kCVPixelBufferHeightKey as String: outputSize.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        pool = nil
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    }

    /// The part of a `width`×`height` depth picture that Fill keeps, in its pixels.
    static func cropRect(width: Int, height: Int, zoom: Float, shiftX: Float, shiftY: Float,
                         output: (width: Int, height: Int)) -> (x: Int, y: Int, w: Int, h: Int) {
        let outWidth = Double(output.width), outHeight = Double(output.height)
        let fillScale = max(outWidth / Double(width), outHeight / Double(height)) * Double(max(zoom, 1))
        let w = max(2, min(width, Int((outWidth / fillScale).rounded())))
        let h = max(2, min(height, Int((outHeight / fillScale).rounded())))
        let x = Int((Double(width - w) / 2 * Double(1 + min(max(shiftX, -1), 1))).rounded())
        let y = Int((Double(height - h) / 2 * Double(1 + min(max(shiftY, -1), 1))).rounded())
        return (x, y, w, h)
    }

    /// The phone's whole picture for setting up, never sent to other apps: in range in the palette,
    /// too near hatched red, too far hatched blue, the hidden room hatched grey, no reading black.
    func overview(millimeters: Data, labels: [UInt8]?, width: Int, height: Int) -> CGImage? {
        colorize(millimeters, labels: labels, width: width, height: height, markers: true)
        guard let provider = CGDataProvider(data: Data(small) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Returns the final camera frame and, if asked, a CGImage of that same frame.
    /// `labels`, when given, is one byte per depth pixel: 0 = background (drawn black),
    /// 1… = player index.
    func render(millimeters: Data, labels: [UInt8]?, width: Int, height: Int, makePreview: Bool) -> (CVPixelBuffer?, CGImage?) {
        colorize(millimeters, labels: labels, width: width, height: height)
        if flipX || flipY { flipSmall(width: width, height: height) }

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
                // A frame-shaped crop of the source into the whole output.
                _ = fillScale
                var (x, y, w, h) = Self.cropRect(width: width, height: height, zoom: cropZoom, shiftX: cropShiftX, shiftY: cropShiftY,
                                                 output: (outWidth, outHeight))
                // the picture was mirrored before cropping, so the kept part moves with it
                if flipX { x = width - x - w }
                if flipY { y = height - y - h }
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

    /// Mirrors `small` in place.
    private func flipSmall(width: Int, height: Int) {
        small.withUnsafeMutableBytes { raw in
            let pixels = raw.bindMemory(to: UInt32.self)
            if flipX {
                for row in 0..<height {
                    var a = row * width, b = row * width + width - 1
                    while a < b { pixels.swapAt(a, b); a += 1; b -= 1 }
                }
            }
            if flipY {
                for row in 0..<(height / 2) {
                    let a = row * width, b = (height - 1 - row) * width
                    for column in 0..<width { pixels.swapAt(a + column, b + column) }
                }
            }
        }
    }

    /// Fills `small` with BGRA colors at the depth map's own resolution.
    private func colorize(_ millimeters: Data, labels: [UInt8]?, width: Int, height: Int, markers: Bool = false) {
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
                        // diagonal stripes for what's being left out, in the setup overview only
                        let stripe: Float = markers && ((i % width + i / width) / 3) % 2 == 0 ? 1 : 0.6
                        if mm == 0 {
                            color = 0xFF00_0000 // no reading: black
                        } else if mm < near || mm > far {
                            // outside the chosen distances: empty for other apps
                            color = !markers ? 0xFF00_0000 : Self.shade(mm < near ? 0xC0262A : 0x2A46B8, by: stripe)
                        } else if labels != nil && player == 0 {
                            color = !markers ? 0xFF00_0000 : Self.shade(0x4A4A4A, by: stripe) // the hidden room
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
