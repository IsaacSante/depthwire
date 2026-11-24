import CoreMediaIO
import Foundation

let providerSource = LidarProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
