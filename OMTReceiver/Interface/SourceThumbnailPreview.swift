import AppKit

/// A thumbnail has no audio path and never owns the fullscreen receiver. The
/// protocol keeps admission/retirement tests independent of the SDK and GPU.
@MainActor
protocol SourceThumbnailPreviewing: AnyObject {
    var source: OMTSource { get }
    var view: NSView { get }
    var statusText: String { get }
    var formatText: String { get }
    var canRetry: Bool { get }
    var onChange: (() -> Void)? { get set }
    func start()
    func retry()
    func stop(completion: @escaping @MainActor @Sendable () -> Void)
}

extension SourceThumbnailPreviewing {
    var canRetry: Bool { false }
    func retry() {}
}

/// Evaluated by the session's existing health updates, without another timer.
/// Successful video resets the delay; failed connection attempts retain it.
struct PreviewReconnectBackoff {
    private var nextDelay: TimeInterval = 1
    private var retryAt: TimeInterval?

    mutating func shouldReconnect(videoState: ReceiverMediaHealth.VideoState, at time: TimeInterval) -> Bool {
        switch videoState {
        case .live:
            reset()
        case .waiting, .unsupported:
            retryAt = nil
        case .stalled:
            guard let retryAt else {
                self.retryAt = time + nextDelay
                return false
            }
            if time >= retryAt {
                self.retryAt = nil
                nextDelay = min(30, nextDelay * 2)
                return true
            }
        }
        return false
    }

    mutating func reset() { nextDelay = 1; retryAt = nil }
}

@MainActor
final class SourceThumbnailPreview: SourceThumbnailPreviewing {
    let source: OMTSource
    let video: VideoView
    var view: NSView { video }
    var onChange: (() -> Void)?
    private let session: ReceiverSession
    private var rendererError: String?
    private var started = false
    private var stopped = false
    private var reconnectBackoff = PreviewReconnectBackoff()
    private var preferenceObserver: NSObjectProtocol?

    var statusText: String { rendererError ?? session.statusText }
    var formatText: String { session.formatText }
    var canRetry: Bool { started && !stopped && (session.isTerminalFailure || session.videoState == .stalled) }

    init(source: OMTSource) {
        self.source = source
        let video = VideoView(frame: .zero, clock: PlaybackClock(latency: 0))
        self.video = video
        video.configurePreviewRendering()
        video.isPaused = true
        video.setAccessibilityElement(false)
        video.onToggleFullscreen = nil
        video.onEscape = nil
        session = ReceiverSession(video: { [video] in video.enqueue($0) }, audio: { _ in }, mode: .preview)
        rendererError = video.errorMessage
        video.onStateChange = { [weak self] in
            guard let self else { return }
            self.rendererError = self.video.errorMessage
            self.onChange?()
        }
        session.onChange = { [weak self] in self?.sessionChanged() }
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .receiverPreferencesChanged, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.applyPreferences() } }
        applyPreferences()
    }

    func start() {
        guard !started, !stopped else { return }
        started = true
        video.isPaused = false
        session.connect(source)
    }

    func stop(completion: @escaping @MainActor @Sendable () -> Void) {
        stopped = true
        reconnectBackoff.reset()
        video.isPaused = true
        // ReceiverSession cancellation fences frame admission before clearing.
        session.stop { [self] in
            video.clear()
            completion()
        }
    }

    /// A deliberate retry uses the session's serial worker: its old SDK
    /// instance is fully destroyed before another instance can be created.
    func retry() {
        guard canRetry else { return }
        reconnectBackoff.reset()
        restart()
    }

    private func sessionChanged() {
        guard started, !stopped else { return }
        let state = session.isTerminalFailure ? ReceiverMediaHealth.VideoState.unsupported : session.videoState
        if reconnectBackoff.shouldReconnect(videoState: state, at: ProcessInfo.processInfo.systemUptime) {
            restart()
        } else {
            onChange?()
        }
    }

    private func restart() {
        // Cancel frame admission before clearing. The serial receive queue
        // destroys the old SDK receiver before starting its replacement.
        session.disconnect()
        video.clear()
        guard started, !stopped else { return }
        session.connect(source)
    }

    private func applyPreferences() {
        let preferences = Preferences.shared
        video.configure(deinterlace: preferences.deinterlace,
                        fieldOrder: preferences.fieldOrder, background: preferences.background)
    }

    deinit {
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
    }
}

/// Owns visible preview workers independently of collection-item reuse. Workers
/// being destroyed still count toward the limit until the SDK has retired them.
@MainActor
final class SourcePreviewCoordinator {
    typealias Factory = @MainActor (OMTSource) -> any SourceThumbnailPreviewing
    let maximumPreviewCount: Int
    var onChange: (() -> Void)?
    private let factory: Factory
    private var desired: [OMTSource] = []
    private var active: [String: any SourceThumbnailPreviewing] = [:]
    private var retiring: [UUID: any SourceThumbnailPreviewing] = [:]
    private var stopping = false
    private var reconciling = false
    private var needsReconcile = false
    private var completions: [@MainActor @Sendable () -> Void] = []

    init(maximumPreviewCount: Int = 12,
         factory: @escaping Factory = { SourceThumbnailPreview(source: $0) }) {
        self.maximumPreviewCount = max(1, maximumPreviewCount)
        self.factory = factory
    }

    var activeIDs: Set<String> { Set(active.keys) }
    var retiringCount: Int { retiring.count }
    var visibleSourceCount: Int { desired.count }
    var pausedVisibleCount: Int { max(0, desired.count - active.count) }
    func preview(for sourceID: String) -> (any SourceThumbnailPreviewing)? { active[sourceID] }
    func canRetry(sourceID: String) -> Bool { !stopping && active[sourceID]?.canRetry == true }
    func retry(sourceID: String) {
        guard canRetry(sourceID: sourceID) else { return }
        active[sourceID]?.retry()
    }

    func setVisibleSources(_ sources: [OMTSource]) {
        guard !stopping else { return }
        var seen = Set<String>()
        let updated = sources.filter { seen.insert($0.id).inserted }
        guard updated != desired else { return }
        desired = updated
        reconcile()
    }

    func stop(completion: @escaping @MainActor @Sendable () -> Void) {
        completions.append(completion)
        stopping = true
        desired = []
        reconcile()
    }

    private func reconcile() {
        if reconciling { needsReconcile = true; return }
        reconciling = true
        repeat {
            needsReconcile = false
            let wanted = Dictionary(desired.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (id, preview) in Array(active) {
                if stopping || wanted[id]?.address != preview.source.address {
                    active.removeValue(forKey: id)
                    retire(preview)
                }
            }
            if !stopping {
                for source in desired where active[source.id] == nil {
                    guard active.count + retiring.count < maximumPreviewCount else { break }
                    let preview = factory(source)
                    active[source.id] = preview
                    preview.onChange = { [weak self] in self?.onChange?() }
                    preview.start()
                }
            }
        } while needsReconcile
        reconciling = false
        onChange?()
        finishIfStopped()
    }

    private func retire(_ preview: any SourceThumbnailPreviewing) {
        preview.onChange = nil
        let token = UUID()
        retiring[token] = preview
        preview.stop { [weak self] in
            guard let self else { return }
            self.retiring.removeValue(forKey: token)
            self.reconcile()
        }
    }

    private func finishIfStopped() {
        guard stopping, active.isEmpty, retiring.isEmpty, !completions.isEmpty else { return }
        let callbacks = completions
        completions.removeAll()
        callbacks.forEach { $0() }
    }
}
