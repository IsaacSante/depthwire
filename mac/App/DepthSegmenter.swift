import Accelerate
import Foundation

/// Kinect-style player segmentation from depth alone, so it works in the dark.
///
/// 1. Capture the empty scene's depth as a background (the phone must stay still).
/// 2. Pixels noticeably closer than the background are foreground.
/// 3. Open the mask (erode, then dilate) to remove speckle.
/// 4. Label connected blobs as players 1…`maxPlayers`, dropping small ones, and keep
///    each player's index stable from frame to frame by matching blob centroids.
/// 5. Optionally keep adapting the background wherever no player is found: depth
///    that got farther (something left) is taken in quickly, depth that got nearer
///    (something arrived and stayed) fades in slowly, so it stops counting as a person.
///
/// Not thread-safe: use from one queue.
final class DepthSegmenter {
    enum BackgroundState: Equatable {
        case none
        case capturing(progress: Double)
        case ready(width: Int, height: Int)
    }

    static let maxPlayers = 6

    var thresholdMillimeters = 150
    var minBlobPixels = 300
    var adaptBackground = true
    /// Per-frame blend toward newly revealed (farther) background, and toward new
    /// static objects (nearer). At 60 fps, 0.002 absorbs a new object in roughly 10 s.
    var revealRate: Float = 0.2
    var absorbRate: Float = 0.002

    private(set) var backgroundState = BackgroundState.none

    private var background: [Float] = []
    private var backgroundWidth = 0
    private var backgroundHeight = 0

    private let framesToCapture = 30
    private var captureSum: [UInt32] = []
    private var captureCount: [UInt16] = []
    private var capturedFrames = 0

    /// Previous frame's player centroids, by player index.
    private var previousCentroids: [UInt8: (x: Double, y: Double)] = [:]

    /// Forgets the recorded empty room.
    func clearBackground() {
        background = []
        backgroundWidth = 0
        backgroundHeight = 0
        previousCentroids = [:]
        backgroundState = .none
    }

    /// The recorded empty room as a file: "DWR1", width and height (UInt16 LE), then Float32 millimetres.
    func exportBackground() -> Data? {
        guard case .ready = backgroundState else { return nil }
        var data = Data("DWR1".utf8)
        for value in [UInt16(backgroundWidth), UInt16(backgroundHeight)] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        background.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        return data
    }

    /// Restores a room saved by `exportBackground`. Returns false if the file isn't one.
    @discardableResult
    func importBackground(_ data: Data) -> Bool {
        guard data.count > 8, data.prefix(4) == Data("DWR1".utf8) else { return false }
        let width = Int(data[4]) | Int(data[5]) << 8, height = Int(data[6]) | Int(data[7]) << 8
        guard width > 0, height > 0, data.count == 8 + width * height * 4 else { return false }
        background = data.dropFirst(8).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        backgroundWidth = width
        backgroundHeight = height
        previousCentroids = [:]
        backgroundState = .ready(width: width, height: height)
        return true
    }

    func beginBackgroundCapture() {
        capturedFrames = 0
        captureSum = []
        captureCount = []
        backgroundState = .capturing(progress: 0)
    }

    /// Feeds one frame. Returns per-pixel player labels (0 = background) once a background
    /// matching this frame's size exists; nil otherwise.
    func process(_ millimeters: Data, width: Int, height: Int) -> [UInt8]? {
        let count = width * height
        let depth = millimeters.withUnsafeBytes { raw in
            raw.bindMemory(to: UInt16.self).map { UInt16(littleEndian: $0) }
        }

        if case .capturing = backgroundState {
            accumulateBackground(depth, width: width, height: height)
            return nil
        }
        guard case .ready = backgroundState, width == backgroundWidth, height == backgroundHeight else { return nil }

        // Foreground: a reading noticeably closer than the background, or anywhere the
        // background had no reading (e.g. it was out of the LiDAR's range).
        var mask = [UInt8](repeating: 0, count: count)
        let threshold = Int(thresholdMillimeters)
        for i in 0..<count {
            let d = Int(depth[i])
            guard d > 0 else { continue }
            let b = Int(background[i])
            if b == 0 || d < b - threshold { mask[i] = 255 }
        }

        open(&mask, width: width, height: height)
        let labels = label(mask, width: width, height: height)
        if adaptBackground { adapt(depth, labels: labels) }
        return labels
    }

    private func adapt(_ depth: [UInt16], labels: [UInt8]) {
        for i in 0..<depth.count where labels[i] == 0 && depth[i] > 0 {
            let d = Float(depth[i])
            let b = background[i]
            if b == 0 {
                background[i] = d
            } else if d > b {
                background[i] = b + (d - b) * revealRate
            } else {
                background[i] = b + (d - b) * absorbRate
            }
        }
    }

    // MARK: - Background

    private func accumulateBackground(_ depth: [UInt16], width: Int, height: Int) {
        let count = width * height
        if captureSum.count != count || backgroundWidth != width || backgroundHeight != height {
            // First frame, or the phone rotated mid-capture: start over at this size.
            captureSum = [UInt32](repeating: 0, count: count)
            captureCount = [UInt16](repeating: 0, count: count)
            capturedFrames = 0
            backgroundWidth = width
            backgroundHeight = height
        }
        for i in 0..<count where depth[i] > 0 {
            captureSum[i] += UInt32(depth[i])
            captureCount[i] += 1
        }
        capturedFrames += 1
        backgroundState = .capturing(progress: Double(capturedFrames) / Double(framesToCapture))

        guard capturedFrames >= framesToCapture else { return }
        // Average of valid samples; pixels valid in under a third of frames count as unknown.
        background = (0..<count).map { i in
            captureCount[i] >= framesToCapture / 3 ? Float(captureSum[i]) / Float(captureCount[i]) : 0
        }
        captureSum = []
        captureCount = []
        previousCentroids = [:]
        backgroundState = .ready(width: width, height: height)
    }

    // MARK: - Cleanup

    /// Morphological opening with a 3x3 kernel: removes isolated pixels and thin noise.
    private func open(_ mask: inout [UInt8], width: Int, height: Int) {
        var scratch = [UInt8](repeating: 0, count: mask.count)
        mask.withUnsafeMutableBytes { maskBytes in
            scratch.withUnsafeMutableBytes { scratchBytes in
                var a = vImage_Buffer(data: maskBytes.baseAddress, height: vImagePixelCount(height),
                                      width: vImagePixelCount(width), rowBytes: width)
                var b = vImage_Buffer(data: scratchBytes.baseAddress, height: vImagePixelCount(height),
                                      width: vImagePixelCount(width), rowBytes: width)
                vImageMin_Planar8(&a, &b, nil, 0, 0, 3, 3, vImage_Flags(kvImageEdgeExtend))
                vImageMax_Planar8(&b, &a, nil, 0, 0, 3, 3, vImage_Flags(kvImageEdgeExtend))
            }
        }
    }

    // MARK: - Player labeling

    private struct Blob {
        var pixels: [Int]
        var centroid: (x: Double, y: Double)
    }

    private func label(_ mask: [UInt8], width: Int, height: Int) -> [UInt8] {
        var visited = [Bool](repeating: false, count: mask.count)
        var blobs: [Blob] = []
        var stack: [Int] = []

        for start in 0..<mask.count where mask[start] != 0 && !visited[start] {
            var pixels: [Int] = []
            var sumX = 0, sumY = 0
            visited[start] = true
            stack.append(start)
            while let i = stack.popLast() {
                pixels.append(i)
                let x = i % width, y = i / width
                sumX += x
                sumY += y
                if x > 0, mask[i - 1] != 0, !visited[i - 1] { visited[i - 1] = true; stack.append(i - 1) }
                if x < width - 1, mask[i + 1] != 0, !visited[i + 1] { visited[i + 1] = true; stack.append(i + 1) }
                if y > 0, mask[i - width] != 0, !visited[i - width] { visited[i - width] = true; stack.append(i - width) }
                if y < height - 1, mask[i + width] != 0, !visited[i + width] { visited[i + width] = true; stack.append(i + width) }
            }
            if pixels.count >= minBlobPixels {
                let n = Double(pixels.count)
                blobs.append(Blob(pixels: pixels, centroid: (Double(sumX) / n, Double(sumY) / n)))
            }
        }

        blobs.sort { $0.pixels.count > $1.pixels.count }
        blobs = Array(blobs.prefix(Self.maxPlayers))

        // Keep indices stable: reuse the index of the nearest previous player within reach.
        let maxJump = Double(max(width, height)) / 6
        var labels = [UInt8](repeating: 0, count: mask.count)
        var used = Set<UInt8>()
        var centroids: [UInt8: (x: Double, y: Double)] = [:]
        for blob in blobs {
            let match = previousCentroids
                .filter { !used.contains($0.key) }
                .map { (index: $0.key, distance: hypot($0.value.x - blob.centroid.x, $0.value.y - blob.centroid.y)) }
                .filter { $0.distance < maxJump }
                .min { $0.distance < $1.distance }
            let index = match?.index ?? (1...UInt8(Self.maxPlayers)).first { !used.contains($0) && previousCentroids[$0] == nil }
                ?? (1...UInt8(Self.maxPlayers)).first { !used.contains($0) }!
            used.insert(index)
            centroids[index] = blob.centroid
            for i in blob.pixels { labels[i] = index }
        }
        previousCentroids = centroids
        return labels
    }
}
