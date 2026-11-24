import Foundation

/// Identity of the virtual camera, shared by the Mac app and the camera extension.
enum CameraConstants {
    static let deviceName = "DepthWire"
    static let deviceID = UUID(uuidString: "87F8B629-43DB-4D7C-8DDE-EDDE8B9AAB8A")!
    static let sourceStreamID = UUID(uuidString: "0721230D-5FB3-4133-8D65-3B8E657A256B")!
    static let sinkStreamID = UUID(uuidString: "EB6AF962-3200-4DE5-9395-001F84714F80")!

    /// The camera's output: 16:9 landscape. Depth in any orientation is fitted inside it.
    static let output = (width: Int32(1280), height: Int32(720))
    /// Formats the camera offers (the extension supports several; one for now).
    static let sizes = [output]

    static let frameRate = 30
}
