import SwiftUI

@main
struct DepthWireApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var controller = StreamController()
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if verticalSizeClass == .compact {
                // Landscape: preview on the left, controls on the right.
                HStack(spacing: 24) {
                    preview
                    VStack(spacing: 16) {
                        title
                        statusText
                        Spacer()
                        streamButton
                    }
                    .frame(maxWidth: 280)
                }
            } else {
                VStack(spacing: 20) {
                    title
                    preview
                    statusText
                    Spacer()
                    streamButton
                }
            }
        }
        .padding()
        // streams as soon as it opens, and picks up again when it comes back from a lock or the
        // background, so an unattended setup never needs a Stream press
        .onAppear {
            controller.startSession()
            if !controller.isStreaming { controller.setStreaming(true) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { controller.resume() }
        }
    }

    private var title: some View {
        Text("DepthWire")
            .font(.largeTitle.bold())
    }

    private var preview: some View {
        Group {
            if let preview = controller.preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .aspectRatio(CGFloat(preview.width) / CGFloat(preview.height), contentMode: .fit)
            } else {
                Color.black
                    .aspectRatio(4 / 3, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusText: some View {
        VStack(spacing: 6) {
            Label(controller.orientationName, systemImage: controller.orientationName.hasPrefix("Portrait")
                  ? "iphone" : "iphone.landscape")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
            linkCard
            speeds
            if controller.isLidarCameraSupported {
                Picker("Depth source", selection: Binding(get: { controller.depthSource },
                                                          set: { controller.setDepthSource($0) })) {
                    ForEach(DepthSource.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                if controller.depthSource == .lidarCamera {
                    Toggle("Fill holes", isOn: Binding(get: { controller.fillHoles },
                                                       set: { controller.setFillHoles($0) }))
                        .frame(maxWidth: 300)
                }
            }
            Toggle("Fast person mask", isOn: Binding(get: { controller.fastMask },
                                                     set: { controller.setFastMask($0) }))
                .frame(maxWidth: 300)
            if let note = controller.thermalNote {
                Label(note, systemImage: "thermometer.high")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .multilineTextAlignment(.center)
    }

    /// Is a Mac taking the depth, and over what.
    private var linkCard: some View {
        let (color, symbol, title, detail): (Color, String, String, String) = {
            switch controller.link {
            case .sending(let count, let via):
                return (.green, via == "Wi-Fi" ? "wifi" : "cable.connector",
                        count == 1 ? "Sending to your Mac" : "Sending to \(count) Mac apps", "Over \(via)")
            case .waiting:
                if let network = controller.network {
                    return (.orange, "desktopcomputer", "Looking for your Mac",
                            "This iPhone is on \(network). Open DepthWire on a Mac on the same network.")
                }
                return (.red, "wifi.slash", "Not on a network",
                        "Join the same Wi-Fi as your Mac, or connect them with a cable.")
            case .problem(let text):
                return (.red, "exclamationmark.triangle", text, controller.status)
            case .stopped:
                return (.gray, "pause.circle", "Stopped", "Press Stream to start sending.")
            }
        }()
        return HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(color).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Circle().fill(color).frame(width: 12, height: 12)
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 340)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.5)))
    }

    /// Live frame rates: depth captured, frames sent to the Mac, and person masks made.
    private var speeds: some View {
        HStack(spacing: 14) {
            speed("Depth", String(format: "%.0f fps", controller.depthFps))
            speed("Sent", controller.isStreaming ? String(format: "%.0f fps", controller.fps) : "–")
            speed("Mask", controller.isStreaming
                  ? String(format: "%.0f fps · %.0f ms", controller.maskFps, controller.maskMilliseconds) : "–")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func speed(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.semibold))
        }
    }

    private var streamButton: some View {
        Button {
            controller.setStreaming(!controller.isStreaming)
        } label: {
            Text(controller.isStreaming ? "Stop" : "Stream")
                .font(.title2.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(controller.isStreaming ? .red : .accentColor)
        .disabled(!controller.isSupported)
    }
}
