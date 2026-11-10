import CoreMediaIO
import Foundation

/// The extension's provider: it publishes one virtual camera device (`CameraDeviceSource`) under a
/// fixed name; the believable name a page reads ("FaceTime HD Camera") is the profile's, applied
/// in the page (`PrivacyScripts.patchSystemCamera`).
final class CameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        // A fixed, distinctive device name — the sentinel the app's shim finds it by to rename or
        // hide per profile (docs/CAMERA.md). The believable name a page reads is applied JS-side.
        deviceSource = CameraDeviceSource(localizedName: CameraExtensionConfig.deviceName)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("the virtual camera device could not be added: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let properties = CMIOExtensionProviderProperties(dictionary: [:])
        properties.manufacturer = "Lumen"
        return properties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
