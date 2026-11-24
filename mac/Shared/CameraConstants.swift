import Foundation

/// Identity of the virtual camera, shared by the Mac app and the camera extension.
enum CameraConstants {
    static let deviceName = "DepthWire"
    static let deviceID = UUID(uuidString: "87F8B629-43DB-4D7C-8DDE-EDDE8B9AAB8A")!
    static let sourceStreamID = UUID(uuidString: "0721230D-5FB3-4133-8D65-3B8E657A256B")!
    static let sinkStreamID = UUID(uuidString: "EB6AF962-3200-4DE5-9395-001F84714F80")!

    /// The camera's default output: 16:9 landscape.
    static let output = (width: Int32(1280), height: Int32(720))
    /// Every size the camera offers. The Mac app renders at the one chosen in its window; an app
    /// that asks the camera for a different one gets that picture fitted into it.
    /// The phone's depth is 4:3 (320×240), so the 4:3 sizes show all of it with no cropping.
    static let sizes = [
        output,
        (width: Int32(640), height: Int32(360)),
        (width: Int32(1920), height: Int32(1080)),
        (width: Int32(640), height: Int32(480)),
        (width: Int32(1440), height: Int32(1080)),
        (width: Int32(1024), height: Int32(1024)),
    ]

    static let frameRate = 30
}
