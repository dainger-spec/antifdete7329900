import CoreMediaIO
import Foundation

/// The extension's provider: it publishes one virtual camera device (`CameraDeviceSource`). The
/// device's name comes from the shared config (the app writes it), so it can read as a built-in
/// camera ("FaceTime HD Camera") rather than announcing itself.
final class CameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = CameraDeviceSource(localizedName: CameraExtensionConfig.current().label)
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
