import Foundation

/// Cleans raw depth before segmentation and rendering:
///
/// - Confidence filtering: drops pixels ARKit is unsure about (reflective, dark or
///   distant surfaces, object edges).
/// - Temporal smoothing: per-pixel exponential moving average to reduce flicker.
///   A large jump (someone moving) resets the pixel instead of leaving a trail.
///
/// Not thread-safe: use from one queue.
final class DepthPreprocessor {
    enum ConfidenceLevel: Int, CaseIterable, Identifiable {
        case all = 0, medium = 1, high = 2
        var id: Self { self }
        var label: String {
            switch self {
            case .all: return "Off"
            case .medium: return "Normal"
            case .high: return "Strict"
            }
        }
    }

    var minConfidence = ConfidenceLevel.medium
    /// 0 = off, up to ~0.9 = heavy. Weight given to the running average each frame.
    var smoothing: Float = 0.5
    /// Readings that differ from the running average by more than this reset it.
    var resetJumpMillimeters: Float = 250

    private var average: [Float] = []

    /// Returns filtered UInt16 millimeter depth, same layout as the input.
    func process(depth: Data, confidence: Data?, width: Int, height: Int) -> Data {
        let count = width * height
        if average.count != count { average = [Float](repeating: 0, count: count) }

        let minLevel = UInt8(minConfidence.rawValue)
        let keep = smoothing
        let jump = resetJumpMillimeters

        var out = Data(count: count * 2)
        depth.withUnsafeBytes { depthRaw in
            let src = depthRaw.bindMemory(to: UInt16.self)
            let conf = confidence.map { [UInt8]($0) }
            out.withUnsafeMutableBytes { outRaw in
                let dst = outRaw.bindMemory(to: UInt16.self)
                average.withUnsafeMutableBufferPointer { avg in
                    for i in 0..<count {
                        var mm = Float(UInt16(littleEndian: src[i]))
                        if let conf, conf[i] < minLevel { mm = 0 }

                        if mm == 0 {
                            avg[i] = 0
                        } else if keep <= 0 || avg[i] == 0 || abs(mm - avg[i]) > jump {
                            avg[i] = mm
                        } else {
                            avg[i] = avg[i] * keep + mm * (1 - keep)
                        }
                        dst[i] = UInt16(avg[i].rounded()).littleEndian
                    }
                }
            }
        }
        return out
    }
}
