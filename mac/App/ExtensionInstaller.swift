import Foundation
import SystemExtensions

/// Activates or removes the bundled camera extension.
final class ExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    var onStatus: ((String) -> Void)?

    private var extensionIdentifier: String {
        Bundle.main.bundleIdentifier! + ".Extension"
    }

    func activate() {
        onStatus?("Installing…")
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivate() {
        onStatus?("Removing…")
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        onStatus?("Allow it in System Settings → General → Login Items & Extensions → Camera Extensions")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed: onStatus?("Installed")
        case .willCompleteAfterReboot: onStatus?("Restart your Mac to finish")
        @unknown default: onStatus?("Done")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        onStatus?("Failed: \(error.localizedDescription)")
    }
}
