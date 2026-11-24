import Foundation

/// Fits the near/far color range to the subject: the 2nd–98th percentile of the
/// isolated people's depth (or of the whole scene when nobody is isolated), padded a
/// little and eased over time so the colors don't pump.
/// Not thread-safe: use from one queue.
final class AutoRange {
    private(set) var nearMeters: Float = 0.2
    private(set) var farMeters: Float = 5
    private var hasValue = false

    private let padding: Float = 0.1
    private let minimumSpan: Float = 0.3
    private let easing: Float = 0.1
    private let minimumSamples = 200

    /// Updates from one frame; keeps the previous range when there's too little depth.
    func update(millimeters: Data, labels: [UInt8]?) {
        // Histogram in centimeters up to 10 m.
        var histogram = [Int](repeating: 0, count: 1001)
        var total = 0
        millimeters.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: UInt16.self)
            for i in 0..<src.count {
                let mm = Int(UInt16(littleEndian: src[i]))
                guard mm > 0, labels.map({ $0[i] > 0 }) ?? true else { continue }
                histogram[min(mm / 10, 1000)] += 1
                total += 1
            }
        }
        guard total >= minimumSamples else { return }

        func percentile(_ p: Double) -> Float {
            let target = Int(Double(total) * p)
            var seen = 0
            for (bin, count) in histogram.enumerated() {
                seen += count
                if seen > target { return Float(bin) / 100 }
            }
            return 10
        }
        var near = max(0, percentile(0.02) - padding)
        var far = percentile(0.98) + padding
        if far - near < minimumSpan {
            let middle = (near + far) / 2
            near = max(0, middle - minimumSpan / 2)
            far = near + minimumSpan
        }

        if hasValue {
            nearMeters += (near - nearMeters) * easing
            farMeters += (far - farMeters) * easing
        } else {
            nearMeters = near
            farMeters = far
            hasValue = true
        }
    }
}
