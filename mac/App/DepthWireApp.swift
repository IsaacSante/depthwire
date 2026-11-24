import AVFoundation
import SwiftUI

@main
struct DepthWireApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("DepthWire") {
            ContentView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

enum IsolateMode {
    case off
    case camera  // Vision person mask from the iPhone's color camera
    case depth   // the recorded empty room, subtracted from the LiDAR depth; works in the dark
}

/// Where the empty-room recording stands, for the button and its caption.
enum RoomState: Equatable {
    case none
    case countdown(Int)
    case recording(Int)   // percent
    case ready
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the window quits, so clicking the Dock icon always starts a fresh session.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Settings that come back on the next launch.
private enum Saved {
    static let store = UserDefaults.standard
    static func double(_ key: String, _ fallback: Double) -> Double { store.object(forKey: key) as? Double ?? fallback }
    static func bool(_ key: String, _ fallback: Bool) -> Bool { store.object(forKey: key) as? Bool ?? fallback }
    static func string(_ key: String) -> String { store.string(forKey: key) ?? "" }
}

final class AppModel: ObservableObject {
    @Published var extensionStatus = "Checking…"
    @Published var phoneStatus = "Starting…"
    @Published var cameraStatus = "Waiting for camera extension"
    /// What the virtual camera is sending to other apps.
    @Published var preview: CGImage?
    /// The phone's whole picture with what's being left out marked, for the corner view.
    @Published var rawPreview: CGImage?
    @Published var fps: Double = 0
    /// Size of the depth frames arriving from the phone (already rotated upright).
    @Published var incomingSize: (width: Int, height: Int)?
    /// Whether the phone is sending a person mask with its frames.
    @Published var hasPersonMask = false

    @Published var nearMeters = Saved.double("near", 0.2) { didSet { changed("near", nearMeters) } }
    @Published var farMeters = Saved.double("far", 5.0) { didSet { changed("far", farMeters) } }
    @Published var autoRange = Saved.bool("autoRange", false) { didSet { changed("autoRange", autoRange) } }
    /// The range auto mode is currently using, for display.
    @Published var autoRangeMeters: (near: Float, far: Float)?
    @Published var palette = DepthRenderer.Palette(rawValue: Saved.string("palette")) ?? .turbo { didSet { changed("palette", palette.rawValue) } }
    @Published var framing = DepthRenderer.Framing(rawValue: Saved.string("framing")) ?? .fill { didSet { changed("framing", framing.rawValue) } }
    @Published var cropZoom = Saved.double("cropZoom", 1) { didSet { changed("cropZoom", cropZoom) } }
    @Published var cropShiftX = Saved.double("cropShiftX", 0) { didSet { changed("cropShiftX", cropShiftX) } }
    @Published var cropShiftY = Saved.double("cropShiftY", 0) { didSet { changed("cropShiftY", cropShiftY) } }
    /// Show the phone's whole picture in the corner while setting up.
    @Published var showOverview = Saved.bool("showOverview", true) { didSet { changed("showOverview", showOverview) } }
    /// Show only what isn't part of the recorded empty room.
    @Published var hideRoom = Saved.bool("hideRoom", false) { didSet { changed("hideRoom", hideRoom) } }
    /// Find people with the phone's color camera instead of the recorded room. Needs light.
    @Published var peopleFromCamera = Saved.bool("peopleFromCamera", false) { didSet { changed("peopleFromCamera", peopleFromCamera) } }
    @Published var playerColors = Saved.bool("playerColors", false) { didSet { changed("playerColors", playerColors) } }
    @Published var thresholdCentimeters = Saved.double("threshold", 15) { didSet { changed("threshold", thresholdCentimeters) } }
    @Published var adaptBackground = Saved.bool("adapt", true) { didSet { changed("adapt", adaptBackground) } }
    @Published var minConfidence = DepthPreprocessor.ConfidenceLevel(rawValue: Int(Saved.double("confidence", 1))) ?? .medium { didSet { changed("confidence", Double(minConfidence.rawValue)) } }
    @Published var smoothing = Saved.double("smoothing", 0.5) { didSet { changed("smoothing", smoothing) } }
    @Published var roomState = RoomState.none
    @Published var crop = CropSettings.load() { didSet { crop.save(); pushSettings() } }
    /// A sample of what the phone sees, in room feet, for the crop-box plots.
    @Published var cropPoints = [SIMD3<Float>]()
    /// The phone's own tilt reading, when its app sends one; the tilt slider is then unused.
    @Published var phoneTilt: Double?
    @Published var playerCount = 0

    private let installer = ExtensionInstaller()
    private let receiver = DepthReceiver()

    // Used only on receiver.queue.
    private let renderer = DepthRenderer()
    private let segmenter = DepthSegmenter()
    private let preprocessor = DepthPreprocessor()
    private let autoRanger = AutoRange()
    private let depthCrop = DepthCrop()
    private var queueAutoRange = false
    private var queueIsolate: IsolateMode = .off
    private var queueOverview = true
    private var lastBackgroundState = DepthSegmenter.BackgroundState.none
    private let sink = VirtualCameraSink()
    private var lastSinkAttempt: CFAbsoluteTime = 0
    private var lastPreview: CFAbsoluteTime = 0
    private var frameCount = 0
    private var fpsWindowStart = CFAbsoluteTimeGetCurrent()

    /// The recorded empty room, kept between launches.
    private static let roomFile: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DepthWire", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("empty-room.bin")
    }()

    init() {
        installer.onStatus = { [weak self] text in self?.extensionStatus = text }
        receiver.onStatus = { [weak self] text in
            DispatchQueue.main.async { self?.phoneStatus = text }
        }
        receiver.onFrame = { [weak self] frame in self?.handleFrame(frame) }

        // Reading the camera list from CoreMediaIO needs camera permission.
        AVCaptureDevice.requestAccess(for: .video) { _ in }
        installer.activate()
        receiver.queue.async { [self] in
            if let data = try? Data(contentsOf: Self.roomFile) { segmenter.importBackground(data) }
        }
        receiver.start()
        receiver.queue.async { [weak self] in self?.connectSinkIfNeeded() }
        pushSettings()
    }

    /// Counts down so you can step out of view, then records the empty room.
    func recordEmptyRoom() {
        if case .countdown = roomState { return }
        if case .recording = roomState { return }
        for remaining in (1...3).reversed() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(3 - remaining)) {
                self.roomState = .countdown(remaining)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.roomState = .recording(0)
            self.receiver.queue.async { self.segmenter.beginBackgroundCapture() }
        }
    }

    /// Forgets the recorded empty room and shows everything again.
    func clearEmptyRoom() {
        hideRoom = false
        receiver.queue.async { [self] in
            segmenter.clearBackground()
            try? FileManager.default.removeItem(at: Self.roomFile)
        }
    }

    /// Every setting back to how the app first opens. The recorded room is kept.
    func resetToDefaults() {
        nearMeters = 0.2; farMeters = 5.0; autoRange = false
        palette = .turbo; framing = .fill
        cropZoom = 1; cropShiftX = 0; cropShiftY = 0; showOverview = true
        hideRoom = false; peopleFromCamera = false; playerColors = false
        thresholdCentimeters = 15; adaptBackground = true
        minConfidence = .medium; smoothing = 0.5
        crop = CropSettings()
    }

    func reinstallExtension() { installer.activate() }
    func removeExtension() { installer.deactivate() }

    private func changed(_ key: String, _ value: Any) {
        Saved.store.set(value, forKey: key)
        pushSettings()
    }

    private func pushSettings() {
        let near = Float(nearMeters), far = Float(farMeters), palette = palette, framing = framing
        let autoRange = autoRange
        let isolate: IsolateMode = !hideRoom ? .off : peopleFromCamera ? .camera : .depth
        let playerColors = playerColors, threshold = Int(thresholdCentimeters * 10)
        let adapt = adaptBackground, minConfidence = minConfidence, smoothing = Float(smoothing)
        let crop = crop
        let zoom = Float(cropZoom), shiftX = Float(cropShiftX), shiftY = Float(cropShiftY), overview = showOverview
        receiver.queue.async { [self] in
            renderer.cropZoom = zoom; renderer.cropShiftX = shiftX; renderer.cropShiftY = shiftY
            queueOverview = overview
            queueIsolate = isolate
            queueAutoRange = autoRange
            segmenter.thresholdMillimeters = threshold
            segmenter.adaptBackground = adapt
            preprocessor.minConfidence = minConfidence
            preprocessor.smoothing = smoothing
            depthCrop.settings = crop
            // with the box on, the colors stretch across just the box
            renderer.nearMeters = crop.enabled ? Float(crop.nearFeet * 0.3048) : near
            renderer.farMeters = crop.enabled ? Float(crop.farFeet * 0.3048) : far
            renderer.framing = framing
            renderer.playerColors = playerColors
            if renderer.palette != palette { renderer.palette = palette }
        }
    }

    // MARK: receiver.queue

    private func connectSinkIfNeeded() {
        guard !sink.isConnected else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSinkAttempt > 2 else { return }
        lastSinkAttempt = now
        let connected = sink.connect()
        DispatchQueue.main.async {
            self.cameraStatus = connected
                ? "“\(CameraConstants.deviceName)” is live. Pick it as the camera in any app."
                : "Waiting for camera extension"
        }
    }

    private func handleFrame(_ frame: DepthReceiver.Frame) {
        connectSinkIfNeeded()

        let width = frame.width, height = frame.height, mask = frame.personMask
        let filtered = preprocessor.process(depth: frame.depth, confidence: frame.confidence,
                                            width: width, height: height)

        let now = CFAbsoluteTimeGetCurrent()
        let wantsPreview = now - lastPreview > 1.0 / 20
        let (millimeters, points) = depthCrop.apply(filtered, width: width, height: height, camera: frame.camera,
                                                    wantsPoints: wantsPreview)
        let measuredTilt = depthCrop.measuredTiltDegrees
        var recording = false
        if case .capturing = segmenter.backgroundState { recording = true }
        let labels: [UInt8]?
        switch queueIsolate {
        case .depth:
            labels = segmenter.process(millimeters, width: width, height: height)
        case .camera:
            labels = mask.map { $0.map { $0 >= 128 ? 1 : 0 } }
            if recording { _ = segmenter.process(millimeters, width: width, height: height) }
        case .off:
            labels = nil
            // a recording has to be fed frames even while the room isn't being hidden
            if recording { _ = segmenter.process(millimeters, width: width, height: height) }
        }
        if segmenter.backgroundState != lastBackgroundState {
            let finished = recording && { if case .ready = segmenter.backgroundState { return true }; return false }()
            lastBackgroundState = segmenter.backgroundState
            let state: RoomState
            switch lastBackgroundState {
            case .none: state = .none
            case .capturing(let progress): state = .recording(Int(progress * 100))
            case .ready: state = .ready
            }
            if finished, let data = segmenter.exportBackground() { try? data.write(to: Self.roomFile) }
            DispatchQueue.main.async {
                self.roomState = state
                // a fresh recording is there to be used
                if finished { self.peopleFromCamera = false; self.hideRoom = true }
            }
        }

        if queueAutoRange && !depthCrop.settings.enabled {
            autoRanger.update(millimeters: millimeters, labels: labels)
            renderer.nearMeters = autoRanger.nearMeters
            renderer.farMeters = autoRanger.farMeters
        }
        let autoRangeMeters = queueAutoRange ? (autoRanger.nearMeters, autoRanger.farMeters) : nil

        // the corner view: the phone's whole picture, with what's being left out marked
        var rawPreview: CGImage?
        if wantsPreview, queueOverview {
            rawPreview = renderer.overview(millimeters: millimeters, labels: labels, width: width, height: height)
        }
        let hiding = queueOverview
        let (pixelBuffer, preview) = renderer.render(millimeters: millimeters, labels: labels, width: width,
                                                     height: height, makePreview: wantsPreview)
        if let pixelBuffer { sink.enqueue(pixelBuffer) }

        frameCount += 1
        var fps: Double?
        if now - fpsWindowStart >= 1 {
            fps = Double(frameCount) / (now - fpsWindowStart)
            frameCount = 0
            fpsWindowStart = now
        }

        if wantsPreview || fps != nil {
            if wantsPreview { lastPreview = now }
            DispatchQueue.main.async {
                if let preview { self.preview = preview }
                if wantsPreview {
                    self.cropPoints = points
                    if hiding { if let rawPreview { self.rawPreview = rawPreview } } else if self.rawPreview != nil { self.rawPreview = nil }
                }
                if self.phoneTilt.map({ Int($0.rounded()) }) != measuredTilt.map({ Int($0.rounded()) }) {
                    self.phoneTilt = measuredTilt
                }
                if let fps { self.fps = fps }
                self.autoRangeMeters = autoRangeMeters
                if self.hasPersonMask != (mask != nil) { self.hasPersonMask = mask != nil }
                let players = labels.map { Set($0).subtracting([0]).count } ?? 0
                if self.playerCount != players { self.playerCount = players }
                if self.incomingSize?.width != width || self.incomingSize?.height != height {
                    self.incomingSize = (width, height)
                }
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("showAdvanced") private var showAdvanced = false

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                feed
                status
            }
            .frame(width: 720)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    distance
                    emptyRoom
                    look
                    advanced
                    Button("Reset all settings") { model.resetToDefaults() }
                        .controlSize(.small)
                        .help("Puts every slider and switch back to how DepthWire first opens. Your calibration is kept.")
                }
                .padding(.trailing, 12)
            }
            .frame(width: 430)
        }
        .padding(20)
        .frame(height: 800)
    }

    // MARK: the picture

    @ViewBuilder private var feed: some View {
        // Exactly what the virtual camera sends to other apps: the 16:9 frame including any bars.
        ZStack {
            if let preview = model.preview {
                Image(decorative: preview, scale: 1).resizable()
            } else {
                Color(white: 0.12)
                    .overlay(Text("No depth yet. Open DepthWire on your iPhone.").foregroundStyle(.secondary))
            }
        }
        .aspectRatio(CGFloat(CameraConstants.output.width) / CGFloat(CameraConstants.output.height),
                     contentMode: .fit)
        .overlay(alignment: .bottomTrailing) {
            if model.showOverview, let raw = model.rawPreview {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Everything the phone sees").font(.caption2).foregroundStyle(.white.opacity(0.9))
                    Image(decorative: raw, scale: 1).interpolation(.none).resizable()
                        .aspectRatio(CGFloat(raw.width) / CGFloat(raw.height), contentMode: .fit)
                        .frame(width: raw.width >= raw.height ? 220 : 130)
                        .overlay {
                            // the part other apps get
                            if model.framing == .fill {
                                GeometryReader { geo in
                                    let r = DepthRenderer.cropRect(width: raw.width, height: raw.height, zoom: Float(model.cropZoom),
                                                                   shiftX: Float(model.cropShiftX), shiftY: Float(model.cropShiftY))
                                    let k = geo.size.width / CGFloat(raw.width)
                                    Rectangle().strokeBorder(.white, lineWidth: 1.5)
                                        .frame(width: CGFloat(r.w) * k, height: CGFloat(r.h) * k)
                                        .offset(x: CGFloat(r.x) * k, y: CGFloat(r.y) * k)
                                }
                            }
                        }
                    Text("Red: too near · Blue: too far · Grey: hidden room").font(.system(size: 9)).foregroundStyle(.white.opacity(0.75))
                }
                .padding(6)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                .padding(10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15)))
        .overlay(alignment: .topLeading) { badge("What other apps get", symbol: "video") }
        .overlay(alignment: .topTrailing) {
            if model.fps > 0 { badge(String(format: "%.0f fps", model.fps), symbol: nil) }
        }
        .overlay {
            if case .countdown(let n) = model.roomState {
                Text("Step out of view… \(n)").font(.largeTitle.bold()).foregroundStyle(.white)
                    .padding(18).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            } else if case .recording = model.roomState {
                RoundedRectangle(cornerRadius: 10).strokeBorder(.red, lineWidth: 5)
                    .overlay(alignment: .top) {
                        Text("Calibrating the empty room").font(.headline).foregroundStyle(.white)
                            .padding(8).background(.red, in: Capsule()).padding(12)
                    }
            }
        }
    }

    @ViewBuilder private var status: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("iPhone").foregroundStyle(.secondary)
                Text(model.phoneStatus)
            }
            GridRow {
                Text("Camera").foregroundStyle(.secondary)
                Text(model.cameraStatus)
            }
            if model.extensionStatus != "Installed" {
                GridRow {
                    Text("Extension").foregroundStyle(.secondary)
                    Text(model.extensionStatus)
                }
            }
        }
        .font(.callout)
    }

    // MARK: setup

    @ViewBuilder private var distance: some View {
        section("1", "Choose the area", "Tell the phone what to pay attention to. Everything outside it is ignored.") {
            Text("How near and how far").font(.subheadline.weight(.semibold))
            Group {
                meterSlider("Nearest", value: $model.nearMeters, range: 0...3)
                meterSlider("Farthest", value: $model.farMeters, range: 0.5...10)
            }
            .disabled(model.autoRange)
            HStack {
                Toggle("Set it for me", isOn: $model.autoRange)
                    .help("Fits the distances to the people in view, or to the whole scene when nobody is.")
                if let range = model.autoRangeMeters {
                    Text(String(format: "%.1f to %.1f m", range.near, range.far))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text("Which part of the picture").font(.subheadline.weight(.semibold)).padding(.top, 6)
            Group {
                plainSlider("Zoom in", value: $model.cropZoom, range: 1...3, format: "%.1f×")
                plainSlider("Left / right", value: $model.cropShiftX, range: -1...1, format: "%+.2f")
                plainSlider("Up / down", value: $model.cropShiftY, range: -1...1, format: "%+.2f")
            }
            .disabled(model.framing != .fill)
            Text(model.framing == .fill ? "The white outline in the corner view shows the part other apps get."
                                        : "Turn off “Show the whole picture with black bars” under Advanced to crop.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var emptyRoom: some View {
        section("2", "Calibrate empty room", "Step out, and DepthWire learns what the room looks like empty. After that it only shows people and things that weren't there. Works in the dark.", highlighted: true) {
            HStack(spacing: 10) {
                Button(action: model.recordEmptyRoom) {
                    Label(recordTitle, systemImage: recordBusy ? "hourglass" : "scope")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
                .disabled(recordBusy)
                Button(action: model.clearEmptyRoom) {
                    Label("Reset calibration", systemImage: "arrow.counterclockwise")
                        .padding(.vertical, 6)
                }
                .controlSize(.extraLarge)
                .disabled(model.roomState != .ready)
                .help("Forgets the calibration and shows the whole room again.")
            }
            Label(roomCaption, systemImage: model.roomState == .ready ? "checkmark.circle.fill" : "info.circle")
                .font(.callout)
                .foregroundStyle(model.roomState == .ready ? Color.green : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.roomState == .ready || model.peopleFromCamera {
                Toggle("Hide the empty room", isOn: $model.hideRoom)
            }
            if model.hideRoom {
                HStack {
                    Text("Sensitivity").frame(width: 84, alignment: .leading)
                    Slider(value: $model.thresholdCentimeters, in: 3...60)
                    Text(String(format: "%.0f cm", model.thresholdCentimeters))
                        .font(.callout.monospacedDigit()).frame(width: 52, alignment: .trailing)
                }
                .help("How far in front of the calibrated room something has to be before it shows. Lower catches more, higher ignores more noise.")
                Text(model.playerCount == 1 ? "1 person in view" : "\(model.playerCount) people in view")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var recordBusy: Bool {
        switch model.roomState {
        case .countdown, .recording: return true
        default: return false
        }
    }

    private var recordTitle: String {
        switch model.roomState {
        case .none: return "Calibrate"
        case .countdown(let n): return "Step out of view… \(n)"
        case .recording(let percent): return "Calibrating… \(percent)%"
        case .ready: return "Calibrate again"
        }
    }

    private var roomCaption: String {
        switch model.roomState {
        case .none: return "Not calibrated yet. Press Calibrate, then you have 3 seconds to step out of view."
        case .countdown, .recording: return "Stay out of view. Almost done…"
        case .ready: return "Calibrated. Do it again if the phone or the furniture moves."
        }
    }

    @ViewBuilder private var look: some View {
        section("3", "Pick a look", "How the depth is drawn for other apps.") {
            Picker("Colors", selection: $model.palette) {
                ForEach(DepthRenderer.Palette.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Give each person their own color", isOn: $model.playerColors)
                .disabled(!model.hideRoom)
        }
    }

    @ViewBuilder private var advanced: some View {
        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show everything the phone sees in the corner", isOn: $model.showOverview)
                    .help("A small view of the phone's whole picture, with what's too near, too far or hidden marked. Other apps never see it.")
                Toggle("Show the whole picture with black bars", isOn: Binding(
                    get: { model.framing == .fit }, set: { model.framing = $0 ? .fit : .fill }))
                    .help("Other apps get the phone's whole picture with black bars at the sides, instead of a cropped picture that fills the frame.")
                Divider()
                Picker("Noise filter", selection: $model.minConfidence) {
                    ForEach(DepthPreprocessor.ConfidenceLevel.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Drops readings the LiDAR is unsure about: shiny or dark surfaces, far walls, edges.")
                HStack {
                    Text("Steadiness").frame(width: 84, alignment: .leading)
                    Slider(value: $model.smoothing, in: 0...0.9)
                    Text(model.smoothing == 0 ? "Off" : String(format: "%.0f%%", model.smoothing * 100))
                        .font(.callout.monospacedDigit()).frame(width: 52, alignment: .trailing)
                }
                .help("Averages each point over time to stop flicker. Higher is steadier but a little slower to react.")
                Picker("Find people with", selection: $model.peopleFromCamera) {
                    Text("The recorded room").tag(false)
                    Text("The phone's camera").tag(true)
                }
                .pickerStyle(.segmented)
                if model.peopleFromCamera {
                    Text(model.hasPersonMask ? "Uses the phone's color camera to find people. Needs decent light."
                                             : "The phone isn't sending a person mask yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Let the recorded room adapt to slow changes", isOn: $model.adaptBackground)
                    .help("Moved furniture slowly blends into the recorded room instead of showing up as a person.")
                Divider()
                cropControls
                Divider()
                HStack {
                    Button("Reinstall camera") { model.reinstallExtension() }
                    Button("Remove camera") { model.removeExtension() }
                }
                .controlSize(.small)
                .help("Installs or removes the “\(CameraConstants.deviceName)” virtual camera.")
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder private var cropControls: some View {
        Toggle("Room box: keep only one part of the room", isOn: $model.crop.enabled)
        if model.crop.enabled {
            VStack(spacing: 2) {
                feetSlider("Phone height", value: $model.crop.phoneHeightFeet, range: 0...10)
                if let tilt = model.phoneTilt {
                    HStack {
                        Text("Phone tilt").frame(width: 84, alignment: .leading)
                        Text(String(format: "%.0f°, measured by the phone", tilt)).foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    degreeSlider("Phone tilt", value: $model.crop.phoneTiltDegrees, range: -45...45)
                }
                feetSlider("Near", value: $model.crop.nearFeet, range: 0...20)
                feetSlider("Far", value: $model.crop.farFeet, range: 1...20)
                feetSlider("Left", value: $model.crop.leftFeet, range: 0...15)
                feetSlider("Right", value: $model.crop.rightFeet, range: 0...15)
                feetSlider("Floor", value: $model.crop.floorFeet, range: 0...6)
                feetSlider("Top", value: $model.crop.topFeet, range: 1...12)
            }
            .font(.callout)
            CropPlot(title: "From the side: floor at the bottom, phone at the left", points: model.cropPoints, crop: model.crop, side: true)
            CropPlot(title: "From above: phone at the left", points: model.cropPoints, crop: model.crop, side: false)
        }
    }

    // MARK: pieces

    private func section<Content: View>(_ number: String, _ title: String, _ explanation: String, highlighted: Bool = false,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(number).font(.callout.bold()).frame(width: 24, height: 24)
                    .background(Color.accentColor, in: Circle()).foregroundStyle(.white)
                Text(title).font(.title3.weight(.semibold))
            }
            Text(explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted ? Color.accentColor.opacity(0.14) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(highlighted ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.08)))
    }

    private func meterSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 84, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.1f m", value.wrappedValue))
                .font(.callout.monospacedDigit()).frame(width: 52, alignment: .trailing)
        }
    }

    private func plainSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        HStack {
            Text(label).frame(width: 84, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.callout.monospacedDigit()).frame(width: 52, alignment: .trailing)
        }
    }

    private func feetSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 84, alignment: .leading)
            Slider(value: value, in: range, step: 0.1)
            Text(String(format: "%.1f ft", value.wrappedValue))
                .monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }

    private func degreeSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 84, alignment: .leading)
            Slider(value: value, in: range, step: 0.5)
            Text(String(format: "%.1f°", value.wrappedValue))
                .monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }

    private func badge(_ text: String, symbol: String?) -> some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.black.opacity(0.6), in: Capsule())
        .foregroundStyle(.white)
        .padding(8)
    }
}

/// What the phone sees from the side or from above, with the crop box drawn on it. Green
/// dots are kept, gray dots are cropped. Tilt is right when the floor lies flat here.
struct CropPlot: View {
    let title: String
    let points: [SIMD3<Float>]
    let crop: CropSettings
    let side: Bool

    private let spanFeet: Float = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Canvas { context, size in
                let scale = min(size.width / CGFloat(spanFeet), size.height / (side ? 11 : 24))
                func spot(_ forward: Float, _ cross: Float) -> CGPoint {
                    let y = side ? size.height - CGFloat(cross) * scale : size.height / 2 - CGFloat(cross) * scale
                    return CGPoint(x: CGFloat(forward) * scale, y: y)
                }
                for point in points {
                    let cross = side ? point.y : point.x
                    let inside = point.z >= Float(crop.nearFeet) && point.z <= Float(crop.farFeet)
                        && point.x >= -Float(crop.leftFeet) && point.x <= Float(crop.rightFeet)
                        && point.y >= Float(crop.floorFeet) && point.y <= Float(crop.topFeet)
                    let at = spot(point.z, cross)
                    context.fill(Path(CGRect(x: at.x, y: at.y, width: 1.5, height: 1.5)),
                                 with: .color(inside ? .green : .gray.opacity(0.5)))
                }
                let lower = side ? Float(crop.floorFeet) : -Float(crop.leftFeet)
                let upper = side ? Float(crop.topFeet) : Float(crop.rightFeet)
                let a = spot(Float(crop.nearFeet), lower), b = spot(Float(crop.farFeet), upper)
                let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                context.stroke(Path(box), with: .color(.yellow), lineWidth: 1)
            }
            .frame(height: 110)
            .background(Color.black.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}
