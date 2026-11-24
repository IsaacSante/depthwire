import ARKit
import AVFoundation
import CoreImage
import CoreMotion
import Network
import UIKit
import Vision

/// Where depth comes from.
enum DepthSource: String, CaseIterable, Identifiable {
    /// ARKit scene depth: 256×192, smoothed with help from the color camera and motion tracking.
    case arkit = "ARKit"
    /// AVFoundation's LiDAR Depth Camera: 320×240, no tracking needed, so it holds up in the dark.
    case lidarCamera = "LiDAR Camera"
    var id: Self { self }
}

/// Captures LiDAR depth (from ARKit or the LiDAR Depth Camera) and, while streaming,
/// serves it to the Mac over a Bonjour-advertised TCP listener.
final class StreamController: NSObject, ObservableObject, ARSessionDelegate, AVCaptureDataOutputSynchronizerDelegate {
    @Published private(set) var isStreaming = false
    @Published private(set) var status = "Idle"
    /// Whether a Mac is taking the depth, and over what.
    enum Link: Equatable {
        case stopped
        case waiting
        case sending(count: Int, via: String)   // "Wi-Fi", "a cable"
        case problem(String)
    }
    @Published private(set) var link = Link.stopped
    /// What the phone itself is connected to: "Wi-Fi", "a cable", or nil when neither.
    @Published private(set) var network: String?
    private let pathMonitor = NWPathMonitor()
    @Published private(set) var preview: CGImage?
    @Published private(set) var fps: Double = 0
    /// Depth frames processed a second, person masks made a second, and how long one mask takes.
    @Published private(set) var depthFps: Double = 0
    @Published private(set) var maskFps: Double = 0
    @Published private(set) var maskMilliseconds: Double = 0
    /// Person mask quality: fast is several times cheaper; balanced is what it used before.
    @Published private(set) var fastMask = UserDefaults.standard.object(forKey: "fastMask4") as? Bool ?? false
    @Published private(set) var orientationName = "Portrait"
    /// Shown while the phone is hot and the frame rate is capped; nil otherwise.
    @Published private(set) var thermalNote: String?
    // Defaults suit a dark room, so nothing needs touching:
    // the LiDAR Camera (no tracking, holds up in the dark), holes filled (off left points
    // blinking in and out, which reads as movement; on is much steadier) and
    // the balanced mask. The "…4" key drops a fill-holes choice saved before this default, and
    // "depthSource5" drops an ARKit choice saved before its picker was hidden.
    @Published private(set) var depthSource = DepthSource(rawValue: UserDefaults.standard.string(forKey: "depthSource5") ?? "")
        ?? .lidarCamera
    /// LiDAR Camera only: let the camera fill holes and reduce noise. Off drops low-confidence points instead.
    @Published private(set) var fillHoles = UserDefaults.standard.object(forKey: "fillHoles4") as? Bool ?? true

    let isSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
    let isLidarCameraSupported = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) != nil

    private let session = ARSession()
    /// Which way is down, sent with every frame so the Mac knows the phone's tilt.
    private let motion = CMMotionManager()
    private let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "depthwire.capture")
    private let depthOutput = AVCaptureDepthDataOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var isCaptureConfigured = false
    private let arQueue = DispatchQueue(label: "depthwire.ar")
    private let netQueue = DispatchQueue(label: "depthwire.net")

    // Accessed only on netQueue.
    private var listener: NWListener?
    // Every Mac app that asked for depth: several Mac apps can listen at once.
    private var connections: [NWConnection] = []
    private var inFlight: Set<ObjectIdentifier> = []
    private var sentFrames = 0
    private var fpsWindowStart = CACurrentMediaTime()

    // Person segmentation runs on the color camera image, off the AR queue.
    private let segmentationQueue = DispatchQueue(label: "depthwire.segmentation", qos: .userInitiated)
    private let ciContext = CIContext()
    private let segmentationRequest: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = UserDefaults.standard.object(forKey: "fastMask4") as? Bool ?? false ? .fast : .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    /// One handler for the whole stream: Vision keeps the mask steady from frame to frame
    /// this way, and it's cheaper than a new handler per frame.
    private let sequenceHandler = VNSequenceRequestHandler()
    /// Reused for every mask instead of allocating a new one each frame (segmentationQueue only).
    private var segmentationInput: CVPixelBuffer?
    // Counted on arQueue, published once a second.
    private var depthFrameCount = 0
    private var maskFrameCount = 0
    private var maskSeconds = 0.0
    private var statsWindowStart = CACurrentMediaTime()

    // Accessed only on arQueue.
    private var lastPreviewTime: CFTimeInterval = 0
    /// Clockwise quarter turns that make the sensor image upright for how the phone is held.
    private var quarterTurns = 0
    private var segmentationEnabled = false
    private var segmentationInFlight = false
    /// Latest person mask, already rotated and sized to match the depth for `turns`.
    private var latestMask: (data: Data, turns: Int)?
    /// Minimum seconds between processed frames; raised as the phone heats up.
    private var minFrameInterval: CFTimeInterval = 0
    private var lastFrameTime: CFTimeInterval = 0

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = arQueue

        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(orientationChanged),
                                               name: UIDevice.orientationDidChangeNotification, object: nil)
        orientationChanged()

        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 30
            motion.startDeviceMotionUpdates()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(thermalStateChanged),
                                               name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        thermalStateChanged()
    }

    /// Caps the frame rate as the phone heats up, so long sessions don't overheat it.
    @objc private func thermalStateChanged() {
        let (fpsCap, note): (Double?, String?)
        switch ProcessInfo.processInfo.thermalState {
        case .serious: (fpsCap, note) = (15, "Phone is hot — limited to 15 fps")
        case .critical: (fpsCap, note) = (5, "Phone is very hot — limited to 5 fps")
        case .fair: (fpsCap, note) = (30, "Phone is warm — limited to 30 fps")
        default: (fpsCap, note) = (nil, nil)
        }
        let interval = fpsCap.map { 1 / $0 * 0.95 } ?? 0
        arQueue.async { self.minFrameInterval = interval }
        DispatchQueue.main.async { self.thermalNote = note }
    }

    @objc private func orientationChanged() {
        // The LiDAR sensor's native image is upright with the phone in landscape, USB-C port on the right.
        let turns: Int
        switch UIDevice.current.orientation {
        case .landscapeLeft: turns = 0; orientationName = "Landscape"
        case .portrait: turns = 1; orientationName = "Portrait"
        case .landscapeRight: turns = 2; orientationName = "Landscape (flipped)"
        case .portraitUpsideDown: turns = 3; orientationName = "Portrait (upside down)"
        default: return // face up/down or unknown: keep the last orientation
        }
        arQueue.async { self.quarterTurns = turns }
    }

    func startSession() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let network: String? = path.status != .satisfied ? nil
                : path.usesInterfaceType(.wiredEthernet) ? "a cable" : path.usesInterfaceType(.wifi) ? "Wi-Fi" : nil
            DispatchQueue.main.async { self?.network = network }
        }
        pathMonitor.start(queue: netQueue)
        guard isSupported else {
            status = "This device has no LiDAR scanner"
            return
        }
        startDepthSource(depthSource)
    }

    func setDepthSource(_ source: DepthSource) {
        guard source != depthSource else { return }
        stopDepthSource(depthSource)
        depthSource = source
        UserDefaults.standard.set(source.rawValue, forKey: "depthSource5")
        startDepthSource(source)
    }

    func setFastMask(_ on: Bool) {
        fastMask = on
        UserDefaults.standard.set(on, forKey: "fastMask4")
        segmentationQueue.async { self.segmentationRequest.qualityLevel = on ? .fast : .balanced }
    }

    func setFillHoles(_ on: Bool) {
        fillHoles = on
        UserDefaults.standard.set(on, forKey: "fillHoles4")
        captureQueue.async { self.depthOutput.isFilteringEnabled = on }
    }

    private func startDepthSource(_ source: DepthSource) {
        switch source {
        case .arkit:
            let config = ARWorldTrackingConfiguration()
            config.frameSemantics = [.smoothedSceneDepth]
            session.run(config)
        case .lidarCamera:
            let fillHoles = fillHoles
            captureQueue.async {
                if !self.isCaptureConfigured {
                    self.isCaptureConfigured = self.configureCapture()
                    guard self.isCaptureConfigured else {
                        DispatchQueue.main.async { self.status = "LiDAR Camera unavailable" }
                        return
                    }
                }
                self.depthOutput.isFilteringEnabled = fillHoles
                self.captureSession.startRunning()
            }
        }
    }

    private func stopDepthSource(_ source: DepthSource) {
        switch source {
        case .arkit: session.pause()
        case .lidarCamera: captureQueue.async { self.captureSession.stopRunning() }
        }
    }

    /// Sets up the LiDAR Depth Camera with a 640×480 color stream and its largest depth format.
    private func configureCapture() -> Bool {
        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        captureSession.sessionPreset = .inputPriority
        guard captureSession.canAddInput(input) else { return false }
        captureSession.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        depthOutput.alwaysDiscardsLateDepthData = true
        guard captureSession.canAddOutput(videoOutput), captureSession.canAddOutput(depthOutput) else { return false }
        captureSession.addOutput(videoOutput)
        captureSession.addOutput(depthOutput)

        // A 4:3 color format (matching the depth's aspect) that supports depth, smallest first.
        let candidates = device.formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return !format.supportedDepthDataFormats.isEmpty && size.width * 3 == size.height * 4 && size.width >= 640
        }
        guard let format = candidates.min(by: {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width
                < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
        }) else { return false }
        let depthFormat = format.supportedDepthDataFormats
            .filter { CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32 }
            .max { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width
                < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            if let depthFormat { device.activeDepthDataFormat = depthFormat }
            device.unlockForConfiguration()
        } catch {
            return false
        }

        let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [depthOutput, videoOutput])
        synchronizer.setDelegate(self, queue: arQueue)
        self.synchronizer = synchronizer
        return true
    }

    func setStreaming(_ on: Bool) {
        isStreaming = on
        UIApplication.shared.isIdleTimerDisabled = on
        let name = UIDevice.current.name
        netQueue.async {
            if on { self.startListener(name: name) } else { self.stopListener() }
        }
        arQueue.async {
            self.segmentationEnabled = on
            if !on { self.latestMask = nil }
        }
    }

    /// Back in the foreground: the listener and the camera may have been stopped while away,
    /// so start them again (streaming stays on unless Stop was pressed).
    func resume() {
        guard isStreaming else { setStreaming(true); return }
        UIApplication.shared.isIdleTimerDisabled = true
        let name = UIDevice.current.name
        netQueue.async {
            self.stopListener()
            self.startListener(name: name)
        }
        startDepthSource(depthSource)
    }

    // MARK: - Depth input (arQueue)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
        let reference = CGSize(width: CVPixelBufferGetWidth(frame.capturedImage),
                               height: CVPixelBufferGetHeight(frame.capturedImage))
        handleDepth(sceneDepth.depthMap, confidence: sceneDepth.confidenceMap, color: frame.capturedImage,
                    timestamp: frame.timestamp, lens: (frame.camera.intrinsics, reference))
    }

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        guard let depth = collection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
              !depth.depthDataWasDropped,
              let video = collection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
              !video.sampleBufferWasDropped,
              let color = CMSampleBufferGetImageBuffer(video.sampleBuffer) else { return }
        let depthData = depth.depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let lens = depthData.cameraCalibrationData.map { ($0.intrinsicMatrix, $0.intrinsicMatrixReferenceDimensions) }
        handleDepth(depthData.depthDataMap, confidence: nil, color: color, timestamp: depth.timestamp.seconds, lens: lens)
    }

    /// Shared path for both sources. `depthMap` is Float32 meters and `color` the matching
    /// camera image, both in the sensor's native landscape orientation. `lens` is the
    /// camera's intrinsics and the image size they were measured at, when the source has them.
    private func handleDepth(_ depthMap: CVPixelBuffer, confidence confidenceMap: CVPixelBuffer?,
                             color: CVPixelBuffer, timestamp: Double, lens: (simd_float3x3, CGSize)?) {
        let now = CACurrentMediaTime()
        guard now - lastFrameTime >= minFrameInterval else { return }
        lastFrameTime = now
        depthFrameCount += 1
        if now - statsWindowStart >= 1 {
            let seconds = now - statsWindowStart
            let depth = Double(depthFrameCount) / seconds, masks = Double(maskFrameCount) / seconds
            let ms = maskFrameCount > 0 ? maskSeconds / Double(maskFrameCount) * 1000 : 0
            depthFrameCount = 0; maskFrameCount = 0; maskSeconds = 0
            statsWindowStart = now
            DispatchQueue.main.async {
                self.depthFps = depth
                self.maskFps = masks
                self.maskMilliseconds = ms
            }
        }
        let sensorSize = CGSize(width: CVPixelBufferGetWidth(depthMap), height: CVPixelBufferGetHeight(depthMap))
        let (millimeters, width, height) = Self.millimeters(from: depthMap, quarterTurns: quarterTurns)

        if now - lastPreviewTime > 1.0 / 15 {
            lastPreviewTime = now
            let image = Self.previewImage(millimeters, width: width, height: height)
            DispatchQueue.main.async { self.preview = image }
        }

        if segmentationEnabled && !segmentationInFlight {
            segmentationInFlight = true
            let image = color
            let turns = quarterTurns
            segmentationQueue.async {
                let start = CACurrentMediaTime()
                let mask = self.personMask(image, quarterTurns: turns, width: width, height: height)
                let took = CACurrentMediaTime() - start
                self.arQueue.async {
                    self.latestMask = mask.map { ($0, turns) }
                    self.segmentationInFlight = false
                    if mask != nil {
                        self.maskFrameCount += 1
                        self.maskSeconds += took
                    }
                }
            }
        }

        // Payload planes, in protocol order: depth, confidence, then the person mask when
        // one matches the current orientation.
        var payload = millimeters
        var flags: DepthWireProtocol.Flags = []
        if let confidence = confidenceMap.flatMap({ Self.confidence(from: $0, quarterTurns: quarterTurns) }) {
            payload.append(confidence)
            flags.insert(.confidence)
        }
        if let mask = latestMask, mask.turns == quarterTurns {
            payload.append(mask.data)
            flags.insert(.personMask)
        }
        if let lens, let gravity = motion.deviceMotion?.gravity {
            payload.append(Self.cameraInfo(lens: lens.0, reference: lens.1, sensorSize: sensorSize,
                                           gravity: gravity, quarterTurns: quarterTurns).encoded())
            flags.insert(.camera)
        }
        netQueue.async { self.send(payload, flags: flags, width: width, height: height, timestamp: timestamp) }
    }

    /// Runs person segmentation on the color image and returns a `width * height` mask
    /// (255 = person) aligned with the rotated depth map.
    private func personMask(_ image: CVPixelBuffer, quarterTurns: Int, width: Int, height: Int) -> Data? {
        // Rotate upright first: the model expects people standing up.
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        var upright = CIImage(cvPixelBuffer: image).oriented(orientations[quarterTurns])
        upright = upright.transformed(by: CGAffineTransform(translationX: -upright.extent.minX, y: -upright.extent.minY))
        let scale = 512 / max(upright.extent.width, upright.extent.height)
        upright = upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let inputWidth = Int(upright.extent.width.rounded()), inputHeight = Int(upright.extent.height.rounded())
        if segmentationInput.map({ CVPixelBufferGetWidth($0) != inputWidth || CVPixelBufferGetHeight($0) != inputHeight }) ?? true {
            var created: CVPixelBuffer?
            CVPixelBufferCreate(nil, inputWidth, inputHeight, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created)
            segmentationInput = created
        }
        guard let input = segmentationInput else { return nil }
        ciContext.render(upright, to: input)

        guard (try? sequenceHandler.perform([segmentationRequest], on: input, orientation: .up)) != nil,
              let maskBuffer = segmentationRequest.results?.first?.pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(maskBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(maskBuffer, .readOnly) }
        let maskWidth = CVPixelBufferGetWidth(maskBuffer)
        let maskHeight = CVPixelBufferGetHeight(maskBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(maskBuffer)
        let base = CVPixelBufferGetBaseAddress(maskBuffer)!.assumingMemoryBound(to: UInt8.self)

        var out = Data(count: width * height)
        out.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let row = base + (y * maskHeight / height) * rowBytes
                for x in 0..<width {
                    dst[y * width + x] = row[x * maskWidth / width]
                }
            }
        }
        return out
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.status = "AR session failed: \(error.localizedDescription)" }
    }

    // MARK: - Networking (netQueue)

    private func startListener(name: String, fixedPort: Bool = true) {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        do {
            params.allowLocalEndpointReuse = true
            // a fixed port, so the Mac can also reach it over USB (usbmuxd), not just by Bonjour
            // (if another app already holds that port, any free port still works over Wi-Fi and Ethernet)
            let listener = fixedPort ? try NWListener(using: params, on: NWEndpoint.Port(rawValue: DepthWireProtocol.usbPort)!)
                                     : try NWListener(using: params)
            listener.service = NWListener.Service(name: name, type: DepthWireProtocol.serviceType)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.publishStreaming()
                case .failed(let error):
                    self?.publishStatus("Couldn't start listening (\(error.localizedDescription)), trying again", .problem("Couldn't start, trying again"))
                    // try again in a second while streaming is on
                    self?.netQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let self, self.listener === listener else { return }
                        self.stopListener()
                        DispatchQueue.main.async {
                            guard self.isStreaming else { return }
                            let name = UIDevice.current.name
                            // second try on any free port, in case the fixed one is taken
                            self.netQueue.async { self.startListener(name: name, fixedPort: !fixedPort) }
                        }
                    }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: netQueue)
            self.listener = listener
        } catch {
            if fixedPort {
                startListener(name: name, fixedPort: false)
            } else {
                publishStatus("Could not start: \(error.localizedDescription)", .problem("Couldn't start"))
            }
        }
    }

    private func stopListener() {
        connections.forEach { $0.cancel() }
        connections = []
        inFlight = []
        listener?.cancel()
        listener = nil
        publishStatus("Idle", .stopped)
        DispatchQueue.main.async { self.fps = 0 }
    }

    private func accept(_ newConnection: NWConnection) {
        connections.append(newConnection)
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection else { return }
            switch state {
            case .ready:
                self.publishStreaming()
            case .failed, .cancelled:
                self.connections.removeAll { $0 === newConnection }
                self.inFlight.remove(ObjectIdentifier(newConnection))
                if self.listener != nil { self.publishStreaming() }
            default:
                break
            }
        }
        newConnection.start(queue: netQueue)
    }

    private func publishStreaming() {
        let ready = connections.filter { $0.state == .ready }
        guard let first = ready.first else { publishStatus("Waiting for Mac…", .waiting); return }
        let path = first.currentPath
        let via = path?.usesInterfaceType(.wiredEthernet) == true ? "a cable" : path?.usesInterfaceType(.wifi) == true ? "Wi-Fi" : "a direct link"
        publishStatus(ready.count == 1 ? "Streaming to Mac" : "Streaming to \(ready.count) Mac apps", .sending(count: ready.count, via: via))
    }

    private func send(_ raw: Data, flags: DepthWireProtocol.Flags, width: Int, height: Int, timestamp: Double) {
        // Drop frames for a listener whose previous one is still in flight, so latency stays low.
        let ready = connections.filter { $0.state == .ready && !inFlight.contains(ObjectIdentifier($0)) }
        guard !ready.isEmpty, let payload = DepthWireProtocol.compress(raw) else { return }
        let header = DepthWireProtocol.Header(
            width: UInt16(width), height: UInt16(height), timestamp: timestamp,
            compressedLength: UInt32(payload.count), rawLength: UInt32(raw.count), flags: flags)
        let message = header.encoded() + payload

        for connection in ready {
            let id = ObjectIdentifier(connection)
            inFlight.insert(id)
            connection.send(content: message, completion: .contentProcessed { [weak self, weak connection] error in
                guard let self else { return }
                self.inFlight.remove(id)
                // count the frame rate from the first listener only
                guard error == nil, let connection, connection === self.connections.first else { return }
                self.sentFrames += 1
                let now = CACurrentMediaTime()
                if now - self.fpsWindowStart >= 1 {
                    let fps = Double(self.sentFrames) / (now - self.fpsWindowStart)
                    self.sentFrames = 0
                    self.fpsWindowStart = now
                    DispatchQueue.main.async { self.fps = fps }
                }
            })
        }
    }

    private func publishStatus(_ text: String, _ link: Link? = nil) {
        DispatchQueue.main.async {
            self.status = text
            if let link { self.link = link }
        }
    }

    // MARK: - Camera info

    /// The lens and which way is down, in the rotated depth image's terms (x right, y up,
    /// z forward out of the back camera).
    private static func cameraInfo(lens: simd_float3x3, reference: CGSize, sensorSize: CGSize,
                                   gravity g: CMAcceleration, quarterTurns: Int) -> DepthWireProtocol.CameraInfo {
        // intrinsics are given for a bigger image; scale them to the depth map, still landscape
        let scale = Float(sensorSize.width / reference.width)
        let fx = lens[0][0] * scale, fy = lens[1][1] * scale
        let cx = lens[2][0] * scale, cy = lens[2][1] * scale
        let w = Float(sensorSize.width), h = Float(sensorSize.height)
        // then turned the same way as the depth (see rotatedIndex)
        let rotated: (Float, Float, Float, Float)
        switch quarterTurns {
        case 1: rotated = (fy, fx, h - cy, cx)
        case 2: rotated = (fx, fy, w - cx, h - cy)
        case 3: rotated = (fy, fx, cy, w - cx)
        default: rotated = (fx, fy, cx, cy)
        }
        // Gravity comes in the phone's own axes: x to the right and y to the top in portrait,
        // z out of the screen. The back camera looks along -z; the image's right and up depend
        // on how the phone is held.
        let device = SIMD3<Float>(Float(g.x), Float(g.y), Float(g.z))
        let axes: (right: SIMD3<Float>, up: SIMD3<Float>)
        switch quarterTurns {
        case 0: axes = ([0, -1, 0], [1, 0, 0])   // landscape, USB-C on the right
        case 2: axes = ([0, 1, 0], [-1, 0, 0])   // landscape, USB-C on the left
        case 3: axes = ([-1, 0, 0], [0, -1, 0])  // portrait, upside down
        default: axes = ([1, 0, 0], [0, 1, 0])   // portrait
        }
        let down = SIMD3<Float>(simd_dot(device, axes.right), simd_dot(device, axes.up), -device.z)
        return DepthWireProtocol.CameraInfo(fx: rotated.0, fy: rotated.1, cx: rotated.2, cy: rotated.3,
                                        gravity: simd_normalize(down))
    }

    // MARK: - Depth conversion

    /// Converts ARKit's Float32 meters into UInt16 millimeters (0 = invalid), rotated
    /// clockwise by `quarterTurns`. Returns the data and its rotated width and height.
    private static func millimeters(from buffer: CVPixelBuffer, quarterTurns: Int) -> (Data, Int, Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let isSideways = quarterTurns % 2 == 1
        let outWidth = isSideways ? height : width
        let outHeight = isSideways ? width : height

        var out = Data(count: width * height * 2)
        out.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: UInt16.self)
            for y in 0..<height {
                let row = (base + y * rowBytes).assumingMemoryBound(to: Float32.self)
                for x in 0..<width {
                    let meters = row[x]
                    let mm: UInt16 = (meters.isFinite && meters > 0) ? UInt16(min(meters * 1000, 65535)) : 0
                    dst[rotatedIndex(x, y, width: width, height: height, quarterTurns: quarterTurns)] = mm.littleEndian
                }
            }
        }
        return (out, outWidth, outHeight)
    }

    /// Rotates ARKit's UInt8 confidence map (0 low, 1 medium, 2 high) the same way as the depth.
    private static func confidence(from buffer: CVPixelBuffer, quarterTurns: Int) -> Data? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)

        var out = Data(count: width * height)
        out.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let row = base + y * rowBytes
                for x in 0..<width {
                    dst[rotatedIndex(x, y, width: width, height: height, quarterTurns: quarterTurns)] = row[x]
                }
            }
        }
        return out
    }

    /// Destination index of sensor pixel (x, y) after rotating the image clockwise by `quarterTurns`.
    @inline(__always)
    private static func rotatedIndex(_ x: Int, _ y: Int, width: Int, height: Int, quarterTurns: Int) -> Int {
        switch quarterTurns {
        case 1: return x * height + (height - 1 - y)
        case 2: return (height - 1 - y) * width + (width - 1 - x)
        case 3: return (width - 1 - x) * height + y
        default: return y * width + x
        }
    }

    /// Grayscale preview: near is bright, 5 m and beyond is dark.
    private static func previewImage(_ millimeters: Data, width: Int, height: Int) -> CGImage? {
        var gray = [UInt8](repeating: 0, count: width * height)
        millimeters.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: UInt16.self)
            for i in 0..<(width * height) {
                let mm = Int(UInt16(littleEndian: src[i]))
                gray[i] = mm == 0 ? 0 : UInt8(255 - min(255, mm * 255 / 5000))
            }
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
