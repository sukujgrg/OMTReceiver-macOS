import AppKit

extension Notification.Name {
    static let receiverPreferencesChanged = Notification.Name("ReceiverPreferencesChanged")
}

@MainActor
final class Preferences {
    static let shared = Preferences()
    let defaults: UserDefaults
    init(defaults: UserDefaults? = nil) {
        if let defaults { self.defaults = defaults }
        else if CommandLine.arguments.contains("--smoke-test") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil {
            self.defaults = UserDefaults(suiteName: "com.OMTReceiver.smoke.\(ProcessInfo.processInfo.processIdentifier)")!
        } else { self.defaults = .standard }
    }
    var fullscreenDisplayID: String {
        get { defaults.string(forKey: "fullscreenDisplayUUID") ?? "" }
        set { defaults.set(newValue, forKey: "fullscreenDisplayUUID"); changed() }
    }
    var discoveryServer: String {
        get { defaults.string(forKey: "discoveryServer") ?? "" }
        set { defaults.set(newValue, forKey: "discoveryServer"); changed() }
    }
    var deinterlace: DeinterlaceMode {
        get { DeinterlaceMode(rawValue: defaults.string(forKey: "deinterlace") ?? "") ?? .automatic }
        set { defaults.set(newValue.rawValue, forKey: "deinterlace"); changed() }
    }
    var fieldOrder: FieldOrder {
        get { FieldOrder(rawValue: defaults.string(forKey: "fieldOrder") ?? "") ?? .topFirst }
        set { defaults.set(newValue.rawValue, forKey: "fieldOrder"); changed() }
    }
    var background: VideoBackground {
        get { VideoBackground(rawValue: defaults.string(forKey: "background") ?? "") ?? .black }
        set { defaults.set(newValue.rawValue, forKey: "background"); changed() }
    }
    private func changed() { NotificationCenter.default.post(name: .receiverPreferencesChanged, object: self) }
}

@MainActor
enum DisplayCatalog {
    nonisolated static func screenRelativeContentRect(for frame: NSRect) -> NSRect {
        NSRect(origin: .zero, size: frame.size)
    }
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    static func identifier(for screen: NSScreen) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID(for: screen))?.takeRetainedValue() else { return "" }
        return CFUUIDCreateString(nil, uuid) as String
    }
    static var mainScreen: NSScreen? {
        NSScreen.screens.first { displayID(for: $0) == CGMainDisplayID() } ?? NSScreen.screens.first
    }
    static func target(identifier: String, screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        let active = screens.filter { $0.frame.width > 0 && $0.frame.height > 0 }
        if !identifier.isEmpty, let screen = active.first(where: { self.identifier(for: $0).caseInsensitiveCompare(identifier) == .orderedSame }) { return screen }
        return active.first { displayID(for: $0) == CGMainDisplayID() } ?? active.first
    }
}
