import Foundation

/// Concrete device models for iOS/iPadOS generations: the self-declared screen geometry and
/// hardware counts the JS device shim reports (`PrivacyScripts`). Values are approximate
/// public numbers for the real devices. This is labelling only — see
/// docs/ISOLATION_AND_LIMITATIONS.md §2 for what a model can and cannot change.
///
/// `deviceMemory` is kept for completeness of the catalog but is NOT exposed to pages:
/// Safari has no `navigator.deviceMemory`, so reporting one would contradict the UA.
public struct DeviceModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let platform: DeviceGeneration.Platform
    public let screenWidth: Int
    public let screenHeight: Int
    public let devicePixelRatio: Double
    public let hardwareConcurrency: Int
    public let deviceMemory: Double
    public let maxTouchPoints: Int

    public init(id: String, name: String, platform: DeviceGeneration.Platform,
                screenWidth: Int, screenHeight: Int, devicePixelRatio: Double,
                hardwareConcurrency: Int, deviceMemory: Double, maxTouchPoints: Int) {
        self.id = id
        self.name = name
        self.platform = platform
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.devicePixelRatio = devicePixelRatio
        self.hardwareConcurrency = hardwareConcurrency
        self.deviceMemory = deviceMemory
        self.maxTouchPoints = maxTouchPoints
    }
}

public enum DeviceModels {
    public static let all: [DeviceModel] = [
        // iPhone
        DeviceModel(id: "iphone-15", name: "iPhone 15", platform: .iOS,
                    screenWidth: 393, screenHeight: 852, devicePixelRatio: 3,
                    hardwareConcurrency: 6, deviceMemory: 6, maxTouchPoints: 5),
        DeviceModel(id: "iphone-16", name: "iPhone 16", platform: .iOS,
                    screenWidth: 393, screenHeight: 852, devicePixelRatio: 3,
                    hardwareConcurrency: 6, deviceMemory: 8, maxTouchPoints: 5),
        DeviceModel(id: "iphone-16-pro", name: "iPhone 16 Pro", platform: .iOS,
                    screenWidth: 402, screenHeight: 874, devicePixelRatio: 3,
                    hardwareConcurrency: 6, deviceMemory: 8, maxTouchPoints: 5),
        DeviceModel(id: "iphone-se", name: "iPhone SE (3rd)", platform: .iOS,
                    screenWidth: 375, screenHeight: 667, devicePixelRatio: 2,
                    hardwareConcurrency: 6, deviceMemory: 4, maxTouchPoints: 5),
        // iPad
        DeviceModel(id: "ipad-pro-11", name: "iPad Pro 11\"", platform: .iPadOS,
                    screenWidth: 834, screenHeight: 1194, devicePixelRatio: 2,
                    hardwareConcurrency: 8, deviceMemory: 8, maxTouchPoints: 5),
        DeviceModel(id: "ipad-air", name: "iPad Air", platform: .iPadOS,
                    screenWidth: 820, screenHeight: 1180, devicePixelRatio: 2,
                    hardwareConcurrency: 8, deviceMemory: 8, maxTouchPoints: 5),
    ]

    public static func forPlatform(_ platform: DeviceGeneration.Platform) -> [DeviceModel] {
        all.filter { $0.platform == platform }
    }

    public static func model(id: String?) -> DeviceModel? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// The model with `id`, but only if it belongs to `platform`. A profile whose generation
    /// was switched (iPad → iPhone) keeps a stale `deviceModelID`; this keeps an iPad screen
    /// from being declared by an iPhone profile.
    public static func model(id: String?, platform: DeviceGeneration.Platform) -> DeviceModel? {
        guard let model = model(id: id), model.platform == platform else { return nil }
        return model
    }

    /// What an iOS/iPadOS profile declares when no model is chosen (the first of its platform).
    /// macOS has no models: those profiles report the real machine.
    public static func defaultModel(for platform: DeviceGeneration.Platform) -> DeviceModel {
        forPlatform(platform).first ?? DeviceModel(id: "generic-\(platform)", name: "Generic", platform: platform,
                                                   screenWidth: 390, screenHeight: 844, devicePixelRatio: 3,
                                                   hardwareConcurrency: 6, deviceMemory: 4, maxTouchPoints: 5)
    }
}
