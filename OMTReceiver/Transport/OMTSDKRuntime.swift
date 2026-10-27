import Foundation

/// One process-wide NativeAOT runtime; instances and discovery share its settings.
final class OMTSDKRuntime: @unchecked Sendable {
    static let shared = OMTSDKRuntime()
    private let lock = NSLock()
    private var loaded = false
    private var shutDown = false
    private var configuredServer = ""
    private var activeServer = ""
    private var failure: String?

    @discardableResult
    func configure(server: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        configuredServer = server
        return loaded && server != activeServer
    }

    func load() -> String? {
        lock.lock(); defer { lock.unlock() }
        if shutDown { return "The OMT SDK has shut down. Relaunch OMTReceiver to receive sources." }
        if loaded { return nil }
        if let failure { return failure }
        guard let folder = Bundle.main.privateFrameworksURL?.appendingPathComponent("OMT", isDirectory: true) else {
            failure = "The app bundle has no Frameworks folder. Rebuild with the SDK embed phase enabled."; return failure
        }
        let storage = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.suku.OMTReceiver.macOS/SDK", isDirectory: true)
        do { try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true) }
        catch { failure = "OMT SDK storage is unavailable: \(error.localizedDescription)"; return failure }
        var message = [CChar](repeating: 0, count: 2048)
        let success = omtr_load(folder.appendingPathComponent("libomt.dylib").path,
                                folder.appendingPathComponent("libvmx.dylib").path,
                                storage.path, configuredServer, &message, message.count)
        if success == 0 { failure = String(cString: message); return failure }
        loaded = true
        activeServer = configuredServer
        return nil
    }

    /// Call exactly once at process exit, after discovery and all sessions stop.
    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        if loaded && !shutDown { omtr_shutdown(); loaded = false; shutDown = true }
    }
}
