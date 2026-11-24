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

enum IsolateMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case camera = "Camera AI"  // Vision person mask from the iPhone's color camera
    case depth = "Depth"       // background subtraction on the LiDAR depth; works in the dark
    var id: Self { self }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the window quits, so clicking the Dock icon always starts a fresh session.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

final class AppModel: ObservableObject {
    @Published var extensionStatus = "Checking…"
    @Published var phoneStatus = "Starting…"
    @Published var cameraStatus = "Waiting for camera extension"
    @Published var preview: CGImage?
    @Published var fps: Double = 0
    /// Size of the depth frames arriving from the phone (already rotated upright).
    @Published var incomingSize: (width: Int, height: Int)?
    /// Whether the phone is sending a person mask with its frames.
    @Published var hasPersonMask = false

    @Published var nearMeters: Double = 0.2 { didSet { pushSettings() } }
    @Published var farMeters: Double = 5.0 { didSet { pushSettings() } }
    @Published var autoRange = false { didSet { pushSettings() } }
    /// The range auto mode is currently using, for display.
    @Published var autoRangeMeters: (near: Float, far: Float)?
    @Published var palette: DepthRenderer.Palette = .turbo { didSet { pushSettings() } }
    @Published var framing: DepthRenderer.Framing = .fit { didSet { pushSettings() } }
    @Published var isolate: IsolateMode = .off { didSet { pushSettings() } }
    @Published var playerColors = false { didSet { pushSettings() } }
    @Published var thresholdCentimeters: Double = 15 { didSet { pushSettings() } }
    @Published var adaptBackground = true { didSet { pushSettings() } }
    @Published var minConfidence: DepthPreprocessor.ConfidenceLevel = .medium { didSet { pushSettings() } }
    @Published var smoothing: Double = 0.5 { didSet { pushSettings() } }
    @Published var backgroundStatus = "Not captured"
    @Published var crop = CropSettings.load() { didSet { crop.save(); pushSettings() } }
    /// A sample of what the phone sees, in room feet, for the calibration plot.
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
    private var lastBackgroundState = DepthSegmenter.BackgroundState.none
    private let sink = VirtualCameraSink()
    private var lastSinkAttempt: CFAbsoluteTime = 0
    private var lastPreview: CFAbsoluteTime = 0
    private var frameCount = 0
    private var fpsWindowStart = CFAbsoluteTimeGetCurrent()

    init() {
        installer.onStatus = { [weak self] text in self?.extensionStatus = text }
        receiver.onStatus = { [weak self] text in
            DispatchQueue.main.async { self?.phoneStatus = text }
        }
        receiver.onFrame = { [weak self] frame in self?.handleFrame(frame) }

        // Reading the camera list from CoreMediaIO needs camera permission.
        AVCaptureDevice.requestAccess(for: .video) { _ in }
        installer.activate()
        receiver.start()
        receiver.queue.async { [weak self] in self?.connectSinkIfNeeded() }
        pushSettings()
    }

    /// Counts down so you can step out of frame, then records the empty scene.
    func captureBackground() {
        for remaining in (1...3).reversed() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(3 - remaining)) {
                self.backgroundStatus = "Step out of frame… \(remaining)"
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.receiver.queue.async { self.segmenter.beginBackgroundCapture() }
        }
    }

    func reinstallExtension() { installer.activate() }
    func removeExtension() { installer.deactivate() }

    private func pushSettings() {
        let near = Float(nearMeters), far = Float(farMeters), palette = palette, framing = framing
        let autoRange = autoRange
        let isolate = isolate, playerColors = playerColors, threshold = Int(thresholdCentimeters * 10)
        let adapt = adaptBackground, minConfidence = minConfidence, smoothing = Float(smoothing)
        let crop = crop
        receiver.queue.async { [self] in
            queueIsolate = isolate
            queueAutoRange = autoRange
            segmenter.thresholdMillimeters = threshold
            segmenter.adaptBackground = adapt
            preprocessor.minConfidence = minConfidence
            preprocessor.smoothing = smoothing
            depthCrop.settings = crop
            // with the box on, the grays stretch across just the box
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
                ? "“\(CameraConstants.deviceName)” is live — pick it in any app"
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
        let labels: [UInt8]?
        switch queueIsolate {
        case .off:
            labels = nil
        case .camera:
            labels = mask.map { $0.map { $0 >= 128 ? 1 : 0 } }
        case .depth:
            labels = segmenter.process(millimeters, width: width, height: height)
        }
        if segmenter.backgroundState != lastBackgroundState {
            lastBackgroundState = segmenter.backgroundState
            let text: String
            switch lastBackgroundState {
            case .none: text = "Not captured"
            case .capturing(let progress): text = "Capturing… \(Int(progress * 100))%"
            case .ready(let w, let h): text = "Captured at \(w)×\(h) — keep the phone still"
            }
            DispatchQueue.main.async { self.backgroundStatus = text }
        }

        if queueAutoRange && !depthCrop.settings.enabled {
            autoRanger.update(millimeters: millimeters, labels: labels)
            renderer.nearMeters = autoRanger.nearMeters
            renderer.farMeters = autoRanger.farMeters
        }
        let autoRangeMeters = queueAutoRange ? (autoRanger.nearMeters, autoRanger.farMeters) : nil

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
                if wantsPreview { self.cropPoints = points }
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

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                feed
                HStack(spacing: 12) {
                    CropPlot(title: "Side: floor at bottom, phone at left", points: model.cropPoints, crop: model.crop, side: true)
                    CropPlot(title: "Top: phone at left", points: model.cropPoints, crop: model.crop, side: false)
                }
                status
            }
            .frame(width: 720)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) { controls }
                    .padding(.trailing, 12)
            }
            .frame(width: 390)
        }
        .padding(20)
        .frame(height: 680)
    }

    @ViewBuilder private var feed: some View {
            // Exactly what the virtual camera outputs: the 16:9 frame including any bars.
            ZStack {
                if let preview = model.preview {
                    Image(decorative: preview, scale: 1).resizable()
                } else {
                    Color(white: 0.12)
                        .overlay(Text("No depth yet").foregroundStyle(.secondary))
                }
            }
            .aspectRatio(CGFloat(CameraConstants.output.width) / CGFloat(CameraConstants.output.height),
                         contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15)))
            .overlay(alignment: .topLeading) {
                if let size = model.incomingSize {
                    badge("\(size.height > size.width ? "Portrait" : "Landscape") in · \(size.width)×\(size.height)",
                          symbol: size.height > size.width ? "iphone" : "iphone.landscape")
                }
            }
            .overlay(alignment: .topTrailing) {
                if model.fps > 0 {
                    badge(String(format: "%.0f fps", model.fps), symbol: nil)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                badge("Out · \(CameraConstants.output.width)×\(CameraConstants.output.height) 16:9", symbol: nil)
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
                GridRow {
                    Text("Extension").foregroundStyle(.secondary)
                    Text(model.extensionStatus)
                }
            }
            .font(.callout)
    }

    @ViewBuilder private var controls: some View {
            HStack(spacing: 20) {
                Picker("Colors", selection: $model.palette) {
                    ForEach(DepthRenderer.Palette.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Framing", selection: $model.framing) {
                    ForEach(DepthRenderer.Framing.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            .pickerStyle(.segmented)

            cropControls

            isolateControls

            HStack(spacing: 16) {
                Picker("Confidence", selection: $model.minConfidence) {
                    ForEach(DepthPreprocessor.ConfidenceLevel.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
            HStack {
                Text("Smoothing")
                Slider(value: $model.smoothing, in: 0...0.9)
                Text(model.smoothing == 0 ? "Off" : String(format: "%.0f%%", model.smoothing * 100))
                    .font(.callout.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }

            HStack {
                Toggle("Auto range", isOn: $model.autoRange)
                    .help("Fit the colors to the isolated people, or to the whole scene when nobody is isolated.")
                if let range = model.autoRangeMeters {
                    Text(String(format: "%.1f – %.1f m", range.near, range.far))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Group {
                rangeSlider("Near", value: $model.nearMeters, range: 0...3)
                rangeSlider("Far", value: $model.farMeters, range: 0.5...10)
            }
            .disabled(model.autoRange)

            HStack {
                Button("Reinstall Extension") { model.reinstallExtension() }
                Button("Remove Extension") { model.removeExtension() }
                Spacer()
            }
            .controlSize(.small)
    }

    @ViewBuilder private var cropControls: some View {
        Toggle("3D crop box: keep only this part of the room", isOn: $model.crop.enabled)
        VStack(spacing: 2) {
            feetSlider("Phone height", value: $model.crop.phoneHeightFeet, range: 0...10)
            if let tilt = model.phoneTilt {
                HStack {
                    Text("Phone tilt").frame(width: 84, alignment: .leading)
                    Text(String(format: "%.0f° measured by the phone, lens from the phone", tilt))
                        .foregroundStyle(.secondary)
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
    }

    private func feetSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 84, alignment: .leading)
            Slider(value: value, in: range, step: 0.1)
            Text(String(format: "%.1f ft", value.wrappedValue))
                .monospacedDigit()
                .frame(width: 50, alignment: .trailing)
        }
    }

    private func degreeSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 84, alignment: .leading)
            Slider(value: value, in: range, step: 0.5)
            Text(String(format: "%.1f°", value.wrappedValue))
                .monospacedDigit()
                .frame(width: 50, alignment: .trailing)
        }
    }

    @ViewBuilder private var isolateControls: some View {
        HStack(spacing: 16) {
            Picker("Isolate people", selection: $model.isolate) {
                ForEach(IsolateMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 250)
            Toggle("Player colors", isOn: $model.playerColors)
                .disabled(model.isolate == .off)
            Spacer()
            if model.isolate != .off {
                Text(model.playerCount == 1 ? "1 person" : "\(model.playerCount) people")
                    .font(.callout.monospacedDigit())
            }
        }

        switch model.isolate {
        case .off:
            EmptyView()
        case .camera:
            Text(model.hasPersonMask
                 ? "Person mask from the iPhone's color camera. Needs decent light."
                 : "No person mask yet. Make sure the phone is streaming.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .depth:
            HStack {
                Button("Capture Background") { model.captureBackground() }
                Text(model.backgroundStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Adapt to room changes", isOn: $model.adaptBackground)
                    .help("Moved furniture slowly blends into the background instead of showing up as a person.")
            }
            HStack {
                Text("Threshold").frame(width: 70, alignment: .leading)
                Slider(value: $model.thresholdCentimeters, in: 3...60)
                Text(String(format: "%.0f cm", model.thresholdCentimeters))
                    .font(.callout.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
            }
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

    private func rangeSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 36, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.1f m", value.wrappedValue))
                .font(.callout.monospacedDigit())
                .frame(width: 52, alignment: .trailing)
        }
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
