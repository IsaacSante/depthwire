import Foundation
import simd

/// The part of the room to keep, in feet. Saved between launches.
struct CropSettings: Codable, Equatable {
    var enabled = false
    var nearFeet = 2.0      // out from the phone
    var farFeet = 14.0
    var leftFeet = 8.0      // to each side of the phone
    var rightFeet = 8.0
    var floorFeet = 0.3     // height above the floor
    var topFeet = 8.5
    var phoneHeightFeet = 5.0
    var phoneTiltDegrees = 0.0  // up is positive

    private static let key = "cropSettings"

    static func load() -> CropSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(CropSettings.self, from: data) else { return CropSettings() }
        return saved
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// Keeps only the depth inside a box in the room. Each pixel becomes a position from the
/// phone's lens and tilt plus the height you dial in, then anything outside goes to 0
/// (no reading). Newer phone apps send their real lens and which way is down with every
/// frame; without them it falls back to an estimated lens and the tilt slider.
/// Not thread-safe: use from one queue.
final class DepthCrop {
    var settings = CropSettings()

    /// The phone doesn't send its lens data yet, so this is the wide camera's view across the
    /// long side of the depth image, near enough to set a box by eye.
    private static let longSideFieldOfView = 65.0 * Double.pi / 180

    private var rayX = [Float]()
    private var rayY = [Float]()
    private var rayKey = SIMD4<Float>(0, 0, 0, 0)
    private var rayWidth = 0, rayHeight = 0

    /// The phone's tilt from its own gravity reading, up positive, while it's sending one.
    private(set) var measuredTiltDegrees: Double?

    private func buildRays(width: Int, height: Int, lens: DepthWireProtocol.CameraInfo?) {
        let estimated = Float(Double(max(width, height)) / 2 / tan(Self.longSideFieldOfView / 2))
        let key = lens.map { SIMD4($0.fx, $0.fy, $0.cx, $0.cy) }
            ?? SIMD4(estimated, estimated, Float(width) / 2, Float(height) / 2)
        // lens values jitter a little from frame to frame; only rebuild for a real change
        guard width != rayWidth || height != rayHeight || simd_reduce_max(simd_abs(key - rayKey)) > 0.5 else { return }
        rayWidth = width
        rayHeight = height
        rayKey = key
        rayX = [Float](repeating: 0, count: width * height)
        rayY = rayX
        for y in 0..<height {
            for x in 0..<width {
                rayX[y * width + x] = (Float(x) + 0.5 - key.z) / key.x
                rayY[y * width + x] = (key.w - Float(y) - 0.5) / key.y
            }
        }
    }

    /// Returns the cropped depth, and a sample of room positions in feet for the calibration
    /// plot (x right, y height above the floor, z out from the phone).
    func apply(_ millimeters: Data, width: Int, height: Int, camera: DepthWireProtocol.CameraInfo?,
               wantsPoints: Bool) -> (Data, [SIMD3<Float>]) {
        buildRays(width: width, height: height, lens: camera)
        let box = settings
        // The room's axes in the camera's: up is against gravity, forward is the lens direction
        // laid flat, right completes them. Without gravity, the tilt slider tips up and forward.
        let up: SIMD3<Float>, forwardAxis: SIMD3<Float>, rightAxis: SIMD3<Float>
        if let g = camera?.gravity, simd_length(g) > 0.5 {
            up = -simd_normalize(g)
            forwardAxis = simd_normalize(SIMD3<Float>(0, 0, 1) - up.z * up)
            rightAxis = simd_cross(up, forwardAxis)
            measuredTiltDegrees = Double(asin(max(-1, min(1, up.z)))) * 180 / .pi
        } else {
            let tilt = Float(box.phoneTiltDegrees * .pi / 180)
            up = SIMD3(0, cos(tilt), sin(tilt))
            forwardAxis = SIMD3(0, -sin(tilt), cos(tilt))
            rightAxis = SIMD3(1, 0, 0)
            measuredTiltDegrees = nil
        }
        let phoneHeight = Float(box.phoneHeightFeet)
        let near = Float(box.nearFeet), far = Float(box.farFeet)
        let left = -Float(box.leftFeet), right = Float(box.rightFeet)
        let floor = Float(box.floorFeet), top = Float(box.topFeet)
        let feetPerMillimeter: Float = 1 / 304.8

        var out = millimeters
        var points = [SIMD3<Float>]()
        if wantsPoints { points.reserveCapacity(width * height / 36) }

        out.withUnsafeMutableBytes { raw in
            let depth = raw.bindMemory(to: UInt16.self)
            for y in 0..<height {
                for x in 0..<width {
                    let i = y * width + x
                    let mm = UInt16(littleEndian: depth[i])
                    if mm == 0 { continue }
                    let z = Float(mm) * feetPerMillimeter
                    let p = SIMD3(rayX[i] * z, rayY[i] * z, z)
                    let height = simd_dot(p, up) + phoneHeight
                    let forward = simd_dot(p, forwardAxis)
                    let side = simd_dot(p, rightAxis)
                    if wantsPoints, x % 6 == 0, y % 6 == 0 {
                        points.append(SIMD3(side, height, forward))
                    }
                    if !box.enabled { continue }
                    if forward < near || forward > far || side < left || side > right || height < floor || height > top {
                        depth[i] = 0
                    }
                }
            }
        }
        return (out, points)
    }
}
