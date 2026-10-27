import Foundation
@preconcurrency import Network

@MainActor
final class OMTDiscoveryManager {
    private(set) var sources: [OMTSource] = []
    private(set) var statusText = "Looking for OMT sources…"
    private(set) var requiresRestart = false
    var onChange: (() -> Void)?
    private var browser: NWBrowser?
    private var sdkTimer: DispatchSourceTimer?
    private let sdkQueue = DispatchQueue(label: "com.suku.OMTReceiver.discovery", qos: .utility)
    private var bonjourSources: [OMTSource] = []
    private var sdkSources: [OMTSource] = []
    private var running = false
    private var generation = UUID()
    private var browserError: String?
    private var sdkError: String?

    func configure(server: String) {
        requiresRestart = OMTSDKRuntime.shared.configure(server: server)
        publish()
    }

    func start() {
        guard !running else { return }
        running = true
        let token = UUID(); generation = token
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_omt._tcp", domain: nil), using: parameters)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.generation == token else { return }
                switch state {
                case .ready: self.browserError = nil
                case .waiting(let error), .failed(let error): self.browserError = "Bonjour: \(error.localizedDescription)"
                default: break
                }
                self.publish()
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> OMTSource? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                // The full Bonjour service instance name is an official SDK address.
                return OMTSource(id: "source:\(name)", name: name, address: name)
            }
            Task { @MainActor [weak self] in
                guard let self, self.running, self.generation == token else { return }
                self.bonjourSources = found; self.publish()
            }
        }
        browser.start(queue: .main)
        let timer = DispatchSource.makeTimerSource(queue: sdkQueue)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            if let error = OMTSDKRuntime.shared.load() {
                Task { @MainActor [weak self] in
                    guard let self, self.running, self.generation == token else { return }
                    self.sdkError = error; self.publish()
                }
                return
            }
            var count: Int32 = 0
            let list = omtr_discover(&count)
            var found: [OMTSource] = []
            if let list, count > 0 && count <= 4096 {
                for index in 0..<Int(count) {
                    guard let pointer = list[index] else { continue }
                    let name = String(cString: pointer)
                    guard !name.isEmpty else { continue }
                    found.append(OMTSource(id: "source:\(name)", name: name, address: name))
                }
            }
            Task { @MainActor [weak self] in
                guard let self, self.running, self.generation == token else { return }
                self.sdkSources = found; self.publish()
            }
        }
        sdkTimer = timer; timer.resume()
    }

    private func publish() {
        let unique = Dictionary((bonjourSources + sdkSources).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let updatedSources = unique.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        let updatedStatus: String
        if requiresRestart { updatedStatus = "Relaunch OMTReceiver to use the new discovery server." }
        else if let sdkError { updatedStatus = sdkError }
        else if let browserError { updatedStatus = browserError }
        else { updatedStatus = updatedSources.isEmpty ? "No sources found. Start an OMT sender or enter its address." : "\(updatedSources.count) OMT source\(updatedSources.count == 1 ? "" : "s") available" }
        // The SDK snapshot is polled every second. Publishing an unchanged list
        // would reload the native source table during clicks and keyboard input.
        guard updatedSources != sources || updatedStatus != statusText else { return }
        sources = updatedSources
        statusText = updatedStatus
        onChange?()
    }

    func stop() {
        running = false; generation = UUID()
        browser?.cancel(); browser = nil
        sdkTimer?.cancel(); sdkTimer = nil
        bonjourSources = []; sdkSources = []; sources = []
    }

    /// Ensures a pending SDK discovery poll has retired before global shutdown.
    func stop(completion: @escaping @MainActor @Sendable () -> Void) {
        // A source's cancellation handler runs after its last event handler,
        // including an event that was already pending when cancel was requested.
        guard let timer = sdkTimer else {
            stop()
            sdkQueue.async { DispatchQueue.main.async(execute: completion) }
            return
        }
        timer.setCancelHandler { DispatchQueue.main.async(execute: completion) }
        stop()
    }
}
