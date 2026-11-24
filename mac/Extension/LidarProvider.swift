import Accelerate
import CoreMediaIO
import CoreText
import CoreVideo
import Foundation
import IOKit.audio
import os.log

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "depthwire.Extension", category: "camera")

private func hostTimeNanoseconds() -> UInt64 {
    UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
}

// MARK: - Device

/// One virtual camera with two streams: a source stream that apps read, and a
/// sink stream the DepthWire Mac app writes depth frames into.
///
/// The camera offers a landscape and a portrait format. Frames from the Mac app are
/// landscape or portrait depending on how the phone is held; when that doesn't match
/// the format the reading app picked, the frame is letterboxed so it stays upright.
final class LidarDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: LidarStreamSource!
    private var sinkStream: LidarSinkStreamSource!

    // One entry per CameraConstants.sizes.
    private var videoDescriptions: [CMFormatDescription] = []
    private var bufferPools: [CVPixelBufferPool] = []
    private var placeholders: [CVPixelBuffer?] = []

    private let outputQueue = DispatchQueue(label: "depthwire.ext.output", qos: .userInteractive)
    private var outputTimer: DispatchSourceTimer?
    private var sourceStreamingCount = 0

    private let lock = NSLock()
    private var activeFormatIndex = 0
    private var latestFrame: CVPixelBuffer?
    private var latestFrameFormatIndex = 0
    private var latestFrameTime: UInt64 = 0
    private var sinkActive = false

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: CameraConstants.deviceID,
                                     legacyDeviceID: nil, source: self)

        let frameDuration = CMTime(value: 1, timescale: Int32(CameraConstants.frameRate))
        var formats: [CMIOExtensionStreamFormat] = []
        for size in CameraConstants.sizes {
            var description: CMFormatDescription?
            CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                           width: size.width, height: size.height,
                                           extensions: nil, formatDescriptionOut: &description)
            let attributes: NSDictionary = [
                kCVPixelBufferWidthKey: size.width,
                kCVPixelBufferHeightKey: size.height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes, &pool)

            videoDescriptions.append(description!)
            bufferPools.append(pool!)
            placeholders.append(nil)
            formats.append(CMIOExtensionStreamFormat(formatDescription: description!, maxFrameDuration: frameDuration,
                                                     minFrameDuration: frameDuration, validFrameDurations: nil))
        }

        sourceStream = LidarStreamSource(localizedName: "\(localizedName) Depth", streamID: CameraConstants.sourceStreamID,
                                         streamFormats: formats, device: device)
        sinkStream = LidarSinkStreamSource(localizedName: "\(localizedName) Input", streamID: CameraConstants.sinkStreamID,
                                           streamFormats: formats, device: device)
        do {
            // Order matters: the Mac app finds the sink as the second stream.
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("Failed to add streams: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "DepthWire"
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func setActiveFormat(_ index: Int) {
        lock.lock()
        activeFormatIndex = index
        lock.unlock()
    }

    // MARK: Source stream output

    func startStreaming() {
        outputQueue.async { [self] in
            sourceStreamingCount += 1
            guard outputTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: outputQueue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(CameraConstants.frameRate), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.emitFrame() }
            timer.resume()
            outputTimer = timer
        }
    }

    func stopStreaming() {
        outputQueue.async { [self] in
            sourceStreamingCount = max(0, sourceStreamingCount - 1)
            if sourceStreamingCount == 0 {
                outputTimer?.cancel()
                outputTimer = nil
            }
        }
    }

    private func emitFrame() {
        lock.lock()
        let target = activeFormatIndex
        let isFresh = hostTimeNanoseconds() &- latestFrameTime < 1_000_000_000
        let frame = isFresh ? latestFrame : nil
        let frameFormat = latestFrameFormatIndex
        lock.unlock()

        let pixelBuffer: CVPixelBuffer?
        if let frame {
            pixelBuffer = frameFormat == target ? frame : letterbox(frame, into: target)
        } else {
            pixelBuffer = placeholderFrame(target)
        }
        guard let pixelBuffer else { return }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(CameraConstants.frameRate)),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                              formatDescription: videoDescriptions[target], sampleTiming: &timing,
                                                              sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else {
            log.error("Failed to create sample buffer: \(status)")
            return
        }
        sourceStream.stream.send(sampleBuffer, discontinuity: [],
                                 hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
    }

    private func makeFilledBuffer(_ index: Int, gray: UInt8) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, bufferPools[index], &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        var dst = vImage_Buffer(data: CVPixelBufferGetBaseAddress(buffer),
                                height: vImagePixelCount(CVPixelBufferGetHeight(buffer)),
                                width: vImagePixelCount(CVPixelBufferGetWidth(buffer)),
                                rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        let color: [UInt8] = [gray, gray, gray, 255] // BGRA
        vImageBufferFill_ARGB8888(&dst, color, vImage_Flags(kvImageNoFlags))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// Dark frame with instructions, shown while no depth is arriving.
    private func placeholderFrame(_ index: Int) -> CVPixelBuffer? {
        if let placeholder = placeholders[index] { return placeholder }
        guard let buffer = makeFilledBuffer(index, gray: 0x20) else { return nil }
        drawWaitingMessage(into: buffer)
        placeholders[index] = buffer
        return buffer
    }

    private func drawWaitingMessage(into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                                          | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }

        func drawCentered(_ text: String, size: CGFloat, white: CGFloat, y: CGFloat) {
            let font = CTFontCreateUIFontForLanguage(.system, size, nil)!
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: white, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            context.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2 - bounds.minX, y: y)
            CTLineDraw(line, context)
        }

        let scale = CGFloat(height) / 720
        drawCentered("DepthWire", size: 54 * scale, white: 0.9, y: CGFloat(height) / 2 + 12 * scale)
        drawCentered("Waiting for depth — open DepthWire on your Mac and iPhone, then tap Stream",
                     size: 24 * scale, white: 0.55, y: CGFloat(height) / 2 - 40 * scale)
    }

    /// Scales `source` to fit inside the format at `index`, centered on black.
    private func letterbox(_ source: CVPixelBuffer, into index: Int) -> CVPixelBuffer? {
        guard let output = makeFilledBuffer(index, gray: 0) else { return nil }
        let srcWidth = CVPixelBufferGetWidth(source), srcHeight = CVPixelBufferGetHeight(source)
        let dstWidth = CVPixelBufferGetWidth(output), dstHeight = CVPixelBufferGetHeight(output)
        let scale = min(Double(dstWidth) / Double(srcWidth), Double(dstHeight) / Double(srcHeight))
        let fitWidth = Int(Double(srcWidth) * scale), fitHeight = Int(Double(srcHeight) * scale)
        let originX = (dstWidth - fitWidth) / 2, originY = (dstHeight - fitHeight) / 2

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        let dstRowBytes = CVPixelBufferGetBytesPerRow(output)
        var src = vImage_Buffer(data: CVPixelBufferGetBaseAddress(source), height: vImagePixelCount(srcHeight),
                                width: vImagePixelCount(srcWidth), rowBytes: CVPixelBufferGetBytesPerRow(source))
        var dst = vImage_Buffer(data: CVPixelBufferGetBaseAddress(output)! + originY * dstRowBytes + originX * 4,
                                height: vImagePixelCount(fitHeight), width: vImagePixelCount(fitWidth),
                                rowBytes: dstRowBytes)
        vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
        CVPixelBufferUnlockBaseAddress(output, [])
        CVPixelBufferUnlockBaseAddress(source, .readOnly)
        return output
    }

    // MARK: Sink stream input

    func startConsuming(from client: CMIOExtensionClient) {
        lock.lock()
        sinkActive = true
        lock.unlock()
        consumeNext(from: client)
    }

    func stopConsuming() {
        lock.lock()
        sinkActive = false
        latestFrame = nil
        lock.unlock()
    }

    private func consumeNext(from client: CMIOExtensionClient) {
        sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, _, hasMoreSampleBuffers, _ in
            guard let self else { return }
            if let sampleBuffer {
                if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    self.store(imageBuffer)
                }
                let output = CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber,
                                                          hostTimeInNanoseconds: hostTimeNanoseconds())
                self.sinkStream.stream.notifyScheduledOutputChanged(output)
            }

            self.lock.lock()
            let active = self.sinkActive
            self.lock.unlock()
            guard active else { return }

            if hasMoreSampleBuffers {
                self.consumeNext(from: client)
            } else {
                self.outputQueue.asyncAfter(deadline: .now() + 1.0 / 120) { self.consumeNext(from: client) }
            }
        }
    }

    /// Copies an incoming frame into our own pool so the sender can reuse its buffer.
    private func store(_ source: CVPixelBuffer) {
        let width = Int32(CVPixelBufferGetWidth(source)), height = Int32(CVPixelBufferGetHeight(source))
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
              let index = CameraConstants.sizes.firstIndex(where: { $0.width == width && $0.height == height }) else { return }

        var copy: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, bufferPools[index], &copy)
        guard let copy else { return }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        let srcRowBytes = CVPixelBufferGetBytesPerRow(source)
        let dstRowBytes = CVPixelBufferGetBytesPerRow(copy)
        let rowLength = min(srcRowBytes, dstRowBytes)
        let src = CVPixelBufferGetBaseAddress(source)!
        let dst = CVPixelBufferGetBaseAddress(copy)!
        for row in 0..<Int(height) {
            memcpy(dst + row * dstRowBytes, src + row * srcRowBytes, rowLength)
        }
        CVPixelBufferUnlockBaseAddress(copy, [])
        CVPixelBufferUnlockBaseAddress(source, .readOnly)

        lock.lock()
        latestFrame = copy
        latestFrameFormatIndex = index
        latestFrameTime = hostTimeNanoseconds()
        lock.unlock()
    }
}

// MARK: - Source stream (what apps see)

final class LidarStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    let formats: [CMIOExtensionStreamFormat]

    init(localizedName: String, streamID: UUID, streamFormats: [CMIOExtensionStreamFormat], device: CMIOExtensionDevice) {
        self.device = device
        self.formats = streamFormats
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source,
                                     clockType: .hostTime, source: self)
    }

    var activeFormatIndex: Int = 0 {
        didSet { (device.source as? LidarDeviceSource)?.setActiveFormat(activeFormatIndex) }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: Int32(CameraConstants.frameRate))
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex, formats.indices.contains(index) {
            activeFormatIndex = index
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        (device.source as? LidarDeviceSource)?.startStreaming()
    }

    func stopStream() throws {
        (device.source as? LidarDeviceSource)?.stopStreaming()
    }
}

// MARK: - Sink stream (fed by the Mac app)

final class LidarSinkStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    let formats: [CMIOExtensionStreamFormat]
    private var client: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, streamFormats: [CMIOExtensionStreamFormat], device: CMIOExtensionDevice) {
        self.device = device
        self.formats = streamFormats
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .sink,
                                     clockType: .hostTime, source: self)
    }

    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: Int32(CameraConstants.frameRate))
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = 1
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex, formats.indices.contains(index) {
            activeFormatIndex = index
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        guard let client, let deviceSource = device.source as? LidarDeviceSource else { return }
        deviceSource.startConsuming(from: client)
    }

    func stopStream() throws {
        (device.source as? LidarDeviceSource)?.stopConsuming()
    }
}

// MARK: - Provider

final class LidarProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: LidarDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = LidarDeviceSource(localizedName: CameraConstants.deviceName)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "DepthWire"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
