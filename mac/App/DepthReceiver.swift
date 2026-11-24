import Foundation
import Network

/// Finds the iPhone over Bonjour (Wi-Fi or peer-to-peer) and reads depth frames.
final class DepthReceiver {
    let queue = DispatchQueue(label: "depthwire.receiver", qos: .userInteractive)

    /// One received frame; planes are `width * height`, see `DepthWireProtocol`.
    struct Frame {
        var depth: Data          // UInt16 millimeters, 0 = no reading
        var confidence: Data?    // UInt8 0 low, 1 medium, 2 high
        var personMask: Data?    // UInt8, 255 = person
        var camera: DepthWireProtocol.CameraInfo? // the phone's lens and which way is down
        var width: Int
        var height: Int
    }

    /// Called on `queue`.
    var onFrame: ((Frame) -> Void)?
    /// Called on `queue`.
    var onStatus: ((String) -> Void)?

    /// Where the link to the phone stands. Called on `queue`.
    enum Link: Equatable {
        case searching                 // no phone found on the network
        case connecting(String)        // found one, no depth yet
        case receiving(String, String) // phone's name, " over Wi-Fi" / " over a cable…"
    }
    var onLink: ((Link) -> Void)?

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var watchdog: DispatchSourceTimer?
    private var lastFrame = Date()
    private var link = Link.searching { didSet { if link != oldValue { onLink?(link) } } }
    private var phoneName = "iPhone"
    private var via = ""

    func start() {
        queue.async { [self] in
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: DepthWireProtocol.serviceType, domain: nil), using: params)
            browser.browseResultsChangedHandler = { [weak self] results, _ in self?.connectIfNeeded(results) }
            browser.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let error):
                    self?.onStatus?("Bonjour failed: \(error)")
                case .waiting(let error):
                    // Typically "PolicyDenied" when Local Network access is off for this app.
                    self?.onStatus?("Bonjour blocked: \(error) — allow DepthWire under Privacy & Security → Local Network")
                default:
                    break
                }
            }
            browser.start(queue: queue)
            self.browser = browser
            // A connection that hangs or goes quiet is dropped after 3 s and tried again, and a phone
            // that shows up while nothing is connected is picked up without waiting for a change.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if let connection = self.connection {
                    if Date().timeIntervalSince(self.lastFrame) > 3 {
                        self.onStatus?("No depth from \(self.phoneName) for 3 seconds, reconnecting…")
                        connection.cancel()
                    }
                } else if let results = self.browser?.browseResults, !results.isEmpty {
                    self.connectIfNeeded(results)
                }
            }
            timer.resume()
            watchdog = timer
            onStatus?("Looking for your iPhone… open DepthWire on it")
        }
    }

    private func connectIfNeeded(_ results: Set<NWBrowser.Result>) {
        guard connection == nil, let result = results.first else { return }

        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let connection = NWConnection(to: result.endpoint, using: params)
        self.connection = connection

        var name = "iPhone"
        if case .service(let serviceName, _, _, _) = result.endpoint { name = serviceName }
        phoneName = name
        lastFrame = Date()   // a new connection gets 3 s to start sending
        link = .connecting(name)
        onStatus?("Found \(name), connecting…")

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.via = Self.describe(connection.currentPath)
                self.onStatus?("Connected to \(name)\(self.via)")
                self.receiveHeader(on: connection)
            case .waiting:
                connection.cancel()
            case .failed, .cancelled:
                guard self.connection === connection else { return }
                self.connection = nil
                self.link = .searching
                self.onStatus?("Looking for your iPhone… open DepthWire on it")
                self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, let results = self.browser?.browseResults else { return }
                    self.connectIfNeeded(results)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// " over Wi-Fi", " over an Ethernet cable"…: which link the depth is arriving on.
    private static func describe(_ path: NWPath?) -> String {
        guard let path else { return "" }
        if path.usesInterfaceType(.wiredEthernet) {
            // a phone on a USB cable shows up as a wired link too
            return " over a cable (Ethernet or USB)"
        }
        if path.usesInterfaceType(.wifi) { return " over Wi-Fi" }
        if path.usesInterfaceType(.other) { return " over a direct link" }
        return ""
    }

    private func receiveHeader(on connection: NWConnection) {
        let size = DepthWireProtocol.headerSize
        connection.receive(minimumIncompleteLength: size, maximumLength: size) { [weak self] data, _, _, error in
            guard let self, error == nil, let data, let header = DepthWireProtocol.Header(data),
                  header.compressedLength > 0 else {
                connection.cancel()
                return
            }
            self.receivePayload(header, on: connection)
        }
    }

    private func receivePayload(_ header: DepthWireProtocol.Header, on connection: NWConnection) {
        let length = Int(header.compressedLength)
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self, error == nil, let data, data.count == length else {
                connection.cancel()
                return
            }
            let width = Int(header.width)
            let height = Int(header.height)
            let pixels = width * height
            if Int(header.rawLength) == header.expectedRawLength,
               let raw = DepthWireProtocol.decompress(data, rawLength: Int(header.rawLength)) {
                var offset = raw.startIndex
                func plane(_ bytes: Int) -> Data {
                    defer { offset += bytes }
                    return Data(raw[offset..<(offset + bytes)])
                }
                let depth = plane(pixels * 2)
                let confidence = header.flags.contains(.confidence) ? plane(pixels) : nil
                let mask = header.flags.contains(.personMask) ? plane(pixels) : nil
                let camera = header.flags.contains(.camera)
                    ? DepthWireProtocol.CameraInfo(plane(DepthWireProtocol.CameraInfo.byteCount)) : nil
                self.lastFrame = Date()
                self.link = .receiving(self.phoneName, self.via)
                self.onFrame?(Frame(depth: depth, confidence: confidence, personMask: mask, camera: camera,
                                    width: width, height: height))
            }
            self.receiveHeader(on: connection)
        }
    }
}
