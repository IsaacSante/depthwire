import CoreMedia
import CoreMediaIO
import Foundation

/// Pushes frames into the camera extension's sink stream through the CoreMediaIO C API.
/// Not thread-safe: use from one queue.
final class VirtualCameraSink {
    private var deviceID: CMIOObjectID = 0
    private var sinkStreamID: CMIOStreamID = 0
    private var bufferQueue: CMSimpleQueue?
    private var formatDescription: CMFormatDescription?

    var isConnected: Bool { bufferQueue != nil }

    init() {
        // Let CoreMediaIO track device changes on its own thread. Without this the camera
        // list is only refreshed on the main run loop, so an extension that is enabled
        // while the app runs isn't seen until relaunch.
        var addr = Self.address(0x726E_6C70) // kCMIOHardwarePropertyRunLoop ('rnlp')
        var runLoop: CFRunLoop?
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil,
                                  UInt32(MemoryLayout<CFRunLoop?>.size), &runLoop)
    }

    /// Finds the "DepthWire" device and starts its sink stream. Returns false if the
    /// extension isn't installed or running yet.
    func connect() -> Bool {
        guard bufferQueue == nil else { return true }
        guard let device = Self.findDevice() else { return false }
        let streams = Self.streams(of: device)
        guard streams.count >= 2 else { return false }
        let sink = streams[1]

        var queue: Unmanaged<CMSimpleQueue>?
        let status = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &queue)
        guard status == noErr, let queue else { return false }
        guard CMIODeviceStartStream(device, sink) == noErr else {
            queue.release()
            return false
        }

        deviceID = device
        sinkStreamID = sink
        bufferQueue = queue.takeRetainedValue()
        return true
    }

    func disconnect() {
        guard bufferQueue != nil else { return }
        CMIODeviceStopStream(deviceID, sinkStreamID)
        bufferQueue = nil
    }

    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        guard let bufferQueue,
              CMSimpleQueueGetCount(bufferQueue) < CMSimpleQueueGetCapacity(bufferQueue) else { return }

        // Recreate when the phone rotates and frames switch between landscape and portrait.
        if let current = formatDescription, !CMVideoFormatDescriptionMatchesImageBuffer(current, imageBuffer: pixelBuffer) {
            formatDescription = nil
        }
        if formatDescription == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
                                                         formatDescriptionOut: &formatDescription)
        }
        guard let formatDescription else { return }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
                                                 formatDescription: formatDescription, sampleTiming: &timing,
                                                 sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { return }

        let element = Unmanaged.passRetained(sampleBuffer)
        if CMSimpleQueueEnqueue(bufferQueue, element: element.toOpaque()) != noErr {
            element.release()
        }
    }

    // MARK: - CMIO lookups

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func objectIDs(of object: CMIOObjectID, selector: Int) -> [CMIOObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    private static func stringProperty(of object: CMIOObjectID, selector: Int) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func findDevice() -> CMIOObjectID? {
        let devices = objectIDs(of: CMIOObjectID(kCMIOObjectSystemObject), selector: kCMIOHardwarePropertyDevices)
        let uid = CameraConstants.deviceID.uuidString
        return devices.first { stringProperty(of: $0, selector: kCMIODevicePropertyDeviceUID) == uid }
            ?? devices.first { stringProperty(of: $0, selector: kCMIOObjectPropertyName) == CameraConstants.deviceName }
    }

    private static func streams(of device: CMIOObjectID) -> [CMIOStreamID] {
        objectIDs(of: device, selector: kCMIODevicePropertyStreams)
    }
}
