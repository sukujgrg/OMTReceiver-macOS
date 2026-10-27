import AppKit

private extension NSToolbarItem.Identifier {
    static let receiverSidebar = Self("receiver.sidebar")
    static let receiverMute = Self("receiver.mute")
    static let receiverReconnect = Self("receiver.reconnect")
    static let receiverFullscreen = Self("receiver.fullscreen")
    static let receiverUpdate = Self("receiver.update")
}

/// A source browser owns silent previews and one independent full-quality output.
/// The browser remains available while that output fills another display.
@MainActor
final class ReceiverWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation {
    private let discovery: OMTDiscoveryManager
    private let updates: AppUpdateViewModel?
    private let screens: () -> [NSScreen]
    private let clock: PlaybackClock
    private let video: VideoView
    private let audio: AudioPlayer
    private lazy var session = ReceiverSession(video: { [video] in video.enqueue($0) }, audio: { [audio] in audio.enqueue($0) })
    let sourceBrowser = SourceBrowserViewController()
    private let pictureHost = NSView()
    private let status = NSTextField(labelWithString: "Sources")
    private let format = NSTextField(labelWithString: "Click a live thumbnail to open fullscreen.")
    private var fullscreen: FullscreenController!
    private var manualSources: [OMTSource] = []
    private var preferenceObserver: NSObjectProtocol?
    private var updateObserver: NSObjectProtocol?
    private var closed = false
    private var shutdownFinished = false
    private var shutdownCompletions: [@MainActor @Sendable () -> Void] = []
    private var audioError: String?
    private var videoError: String?
    private(set) var muted = false
    var onWindowWillClose: ((ReceiverWindowController) -> Void)?
    var onClose: ((ReceiverWindowController) -> Void)?
    var onCheckForUpdates: ((NSWindow?) -> Void)?
    var onRevealControls: ((NSWindow?) -> Void)?
    var isFullscreen: Bool { fullscreen?.isFullscreen ?? false }
    var fullscreenDisplayID: String? {
        guard isFullscreen, let screen = video.window?.screen else { return nil }
        return DisplayCatalog.identifier(for: screen)
    }
    var selectedSource: OMTSource? { session.source }

    init(discovery: OMTDiscoveryManager, number: Int, updates: AppUpdateViewModel? = nil,
         frameAutosaveName: NSWindow.FrameAutosaveName? = nil,
         screens: @escaping () -> [NSScreen] = { NSScreen.screens }) {
        self.discovery = discovery; self.updates = updates; self.screens = screens
        let clock = PlaybackClock(); self.clock = clock
        video = VideoView(frame: .zero, clock: clock)
        video.isPaused = true
        audio = AudioPlayer(clock: clock)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "OMTReceiver"
        window.minSize = NSSize(width: 680, height: 430)
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenNone]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        shouldCascadeWindows = false
        window.delegate = self
        build()
        let savedFrame = frameAutosaveName ?? Self.defaultFrameAutosaveName(number: number)
        // Restore the finished AppKit frame, including its toolbar. Register
        // autosaving afterward so initial placement cannot overwrite a saved frame.
        if !window.setFrameUsingName(savedFrame) {
            if number == 1 { window.center() }
            else { window.cascadeTopLeft(from: NSPoint(x: 100 + number * 22, y: 800 - number * 22)) }
        }
        window.setFrameAutosaveName(savedFrame)
        fullscreen = FullscreenController(owner: window, home: pictureHost, video: video, keepOwnerVisible: true, screens: screens)
        fullscreen.restoreOwnerFocus = { [weak self] in self?.sourceBrowser.focusSelectedSource() }
        fullscreen.onChange = { [weak self] in self?.fullscreenChanged() }
        // Source cards are the activation surface. Clicking the output picture
        // does not accidentally leave fullscreen; Escape is the exit command.
        video.onToggleFullscreen = nil
        video.setAccessibilityHelp("Fullscreen output. Press Escape to return to sources.")
        video.onEscape = { [weak self] in self?.fullscreen.exit() }
        video.onStateChange = { [weak self] in
            guard let self else { return }
            self.videoError = self.video.errorMessage; self.updateState()
        }
        videoError = video.errorMessage
        audio.onStateChange = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.audioError = self.audio.errorMessage; self.updateState()
            }
        }
        sourceBrowser.onActivate = { [weak self] source in self?.connect(source) }
        sourceBrowser.onConnectAddress = { [weak self] in self?.connectAddress(nil) }
        sourceBrowser.onEscape = { [weak self] in self?.fullscreen.exit() }
        session.onChange = { [weak self] in self?.updateState() }
        preferenceObserver = NotificationCenter.default.addObserver(forName: .receiverPreferencesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPreferences() }
        }
        if let updates {
            updateObserver = NotificationCenter.default.addObserver(forName: .receiverUpdateStateChanged, object: updates, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshUpdateBadge() }
            }
        }
        refreshUpdateBadge()
        applyPreferences()
        refreshDiscovery()
        updateState()
    }
    required init?(coder: NSCoder) { fatalError("Use init(discovery:number:updates:)") }

    private static func defaultFrameAutosaveName(number: Int) -> NSWindow.FrameAutosaveName {
        let name = "ReceiverWindow\(number)"
        // NSWindow writes to standard defaults, independently of Preferences'
        // isolated test suite. Tests and smoke runs must not replace user frames.
        if CommandLine.arguments.contains("--smoke-test") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil {
            return "OMTReceiver.Test.\(ProcessInfo.processInfo.processIdentifier).\(name)"
        }
        return name
    }

    private func build() {
        guard let window else { return }
        let root = NSViewController(); root.view = NSView()
        root.addChild(sourceBrowser)
        window.contentViewController = root
        let browser = sourceBrowser.view
        browser.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(browser)
        pictureHost.isHidden = true
        pictureHost.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(pictureHost)
        video.translatesAutoresizingMaskIntoConstraints = false
        pictureHost.addSubview(video)
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.setAccessibilityLabel("Connection status")
        format.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        format.textColor = .secondaryLabelColor
        format.lineBreakMode = .byTruncatingTail
        format.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        format.setAccessibilityLabel("Stream format")
        let footer = NSStackView(views: [status, format])
        footer.orientation = .vertical; footer.alignment = .leading; footer.spacing = 4
        footer.translatesAutoresizingMaskIntoConstraints = false; root.view.addSubview(footer)
        let line = NSBox(); line.boxType = .separator; line.translatesAutoresizingMaskIntoConstraints = false; root.view.addSubview(line)
        NSLayoutConstraint.activate([
            browser.leadingAnchor.constraint(equalTo: root.view.leadingAnchor), browser.trailingAnchor.constraint(equalTo: root.view.trailingAnchor), browser.topAnchor.constraint(equalTo: root.view.topAnchor), browser.bottomAnchor.constraint(equalTo: line.topAnchor),
            line.leadingAnchor.constraint(equalTo: root.view.leadingAnchor), line.trailingAnchor.constraint(equalTo: root.view.trailingAnchor), line.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: root.view.leadingAnchor, constant: 20), footer.trailingAnchor.constraint(equalTo: root.view.trailingAnchor, constant: -20), footer.bottomAnchor.constraint(equalTo: root.view.bottomAnchor, constant: -10), footer.heightAnchor.constraint(equalToConstant: 32),
            pictureHost.leadingAnchor.constraint(equalTo: root.view.leadingAnchor), pictureHost.topAnchor.constraint(equalTo: root.view.topAnchor), pictureHost.widthAnchor.constraint(equalToConstant: 1), pictureHost.heightAnchor.constraint(equalToConstant: 1),
            video.leadingAnchor.constraint(equalTo: pictureHost.leadingAnchor), video.trailingAnchor.constraint(equalTo: pictureHost.trailingAnchor), video.topAnchor.constraint(equalTo: pictureHost.topAnchor), video.bottomAnchor.constraint(equalTo: pictureHost.bottomAnchor)
        ])
        // AppKit synchronizes item insertions/removals between toolbars with the
        // same identifier. Each receiver owns its dynamic update item and lifetime.
        let toolbar = NSToolbar(identifier: "ReceiverToolbar.\(UUID().uuidString)")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        window.toolbar = toolbar; window.toolbarStyle = .unified
    }

    func refreshDiscovery() {
        guard !closed else { return }
        var sources = [OMTSource.testPattern]
        for source in discovery.sources + manualSources + [session.source].compactMap({ $0 }) where !sources.contains(where: { $0.id == source.id }) { sources.append(source) }
        sourceBrowser.update(sources: sources, status: discovery.statusText, selectedSource: session.source)
    }

    /// One activation starts full-quality playback and presents it immediately.
    /// Activating the same tile again leaves the existing output in place.
    func connect(_ source: OMTSource) {
        guard !closed else { return }
        guard DisplayCatalog.target(identifier: Preferences.shared.fullscreenDisplayID, screens: screens()) != nil else {
            status.stringValue = "Connect a display to open fullscreen output."
            return
        }
        if session.source?.id != source.id || session.source?.address != source.address {
            session.disconnect()
            audio.stop(); video.clear(); clock.reset(); audioError = nil
            audio.setMuted(muted)
            video.isPaused = false
            session.connect(source)
        }
        fullscreen.enter()
        refreshDiscovery()
        updateState()
    }
    private func fullscreenChanged() {
        if !isFullscreen && !fullscreen.isRetargeting {
            session.disconnect()
            audio.stop(); video.clear(); clock.reset(); video.isPaused = true
        }
        refreshDiscovery(); updateState()
    }
    private func applyPreferences() {
        let p = Preferences.shared
        video.configure(deinterlace: p.deinterlace, fieldOrder: p.fieldOrder, background: p.background)
    }
    private func updateState() {
        guard !closed else { return }
        window?.title = session.source.map { "OMTReceiver — \($0.name)" } ?? "OMTReceiver"
        if let title = window?.title { fullscreen?.updateTitle(title) }
        let errors = [videoError.map { "Video: \($0)" }, audioError.map { "Audio: \($0)" }].compactMap { $0 }
        status.stringValue = session.source.map { "\($0.name) · \(session.statusText)" } ?? "Sources"
        if !errors.isEmpty { status.stringValue += " · " + errors.joined(separator: " · ") }
        status.toolTip = status.stringValue
        format.stringValue = session.source == nil ? "Click a live thumbnail to open fullscreen. Previews are silent." : (session.formatText.isEmpty ? "Connecting to full-quality video and audio…" : session.formatText)
        format.toolTip = format.stringValue
        updateToolbar()
    }
    private func updateToolbar() {
        window?.toolbar?.items.forEach { item in
            if item.itemIdentifier == .receiverMute {
                item.isEnabled = session.source != nil
                item.image = NSImage(systemSymbolName: muted ? "speaker.slash" : "speaker.wave.2", accessibilityDescription: muted ? "Unmute Audio" : "Mute Audio")
                item.label = muted ? "Unmute" : "Mute"; item.toolTip = muted ? "Unmute Output Audio (⇧⌘M)" : "Mute Output Audio (⇧⌘M)"
            }
            if item.itemIdentifier == .receiverReconnect { item.isEnabled = session.source != nil }
            if item.itemIdentifier == .receiverFullscreen {
                item.image = NSImage(systemSymbolName: isFullscreen ? "stop" : "arrow.up.left.and.arrow.down.right", accessibilityDescription: isFullscreen ? "Stop Fullscreen Output" : "Open Source Fullscreen")
                item.label = isFullscreen ? "Stop Output" : "Fullscreen"
            }
        }
    }
    private func refreshUpdateBadge() {
        guard !closed, let toolbar = window?.toolbar else { return }
        let index = toolbar.items.firstIndex { $0.itemIdentifier == .receiverUpdate }
        if updates?.isUpdateAvailable == true, index == nil { toolbar.insertItem(withItemIdentifier: .receiverUpdate, at: toolbar.items.count) }
        else if updates?.isUpdateAvailable != true, let index { toolbar.removeItem(at: index) }
        if let item = toolbar.items.first(where: { $0.itemIdentifier == .receiverUpdate }) { renderUpdateBadge(item) }
    }
    private func renderUpdateBadge(_ item: NSToolbarItem) {
        let label = updates?.availableVersion.map { "Update available: OMTReceiver " + $0 } ?? "Update"
        item.label = label; item.paletteLabel = label
        item.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: label)
        item.isEnabled = updates?.isUpdateAvailable == true && updates?.canCheckForUpdates == true
        item.toolTip = item.isEnabled ? "Show update details for OMTReceiver " + (updates?.availableVersion ?? "") : label + ". Update controls are temporarily unavailable."
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard !closed else { return false }
        if item.itemIdentifier == .receiverUpdate { return updates?.isUpdateAvailable == true && updates?.canCheckForUpdates == true }
        if item.itemIdentifier == .receiverReconnect || item.itemIdentifier == .receiverMute { return session.source != nil }
        return true
    }
    func revealControlsForDialog() {
        fullscreen.showControls()
        window?.makeKeyAndOrderFront(nil)
        sourceBrowser.focusSelectedSource()
    }
    @objc private func showUpdate(_ sender: Any?) {
        guard updates?.canCheckForUpdates == true else { return }
        if let onCheckForUpdates { onCheckForUpdates(window); return }
        // A browser on a different screen can show native update UI while the
        // external display continues receiving its selected source.
        if fullscreenDisplayID == window?.screen.map(DisplayCatalog.identifier) { fullscreen.showControls() }
        window?.makeKeyAndOrderFront(nil)
        updates?.checkForUpdates()
    }
    @objc func toggleMute(_ sender: Any?) { muted.toggle(); audio.setMuted(muted); updateToolbar() }
    @objc func toggleFullscreen(_ sender: Any?) {
        if isFullscreen { fullscreen.exit() }
        else if let source = sourceBrowser.activationSource { connect(source) }
    }
    @objc func reconnect(_ sender: Any?) {
        guard let source = session.source else { return }
        session.disconnect(); audio.stop(); video.clear(); clock.reset(); audioError = nil
        video.isPaused = false; session.connect(source)
    }
    @objc func disconnect(_ sender: Any?) {
        if isFullscreen { fullscreen.exit() }
        else { session.disconnect(); audio.stop(); video.clear(); video.isPaused = true; refreshDiscovery(); updateState() }
    }
    @objc func toggleSidebar(_ sender: Any?) {
        // Another receiver may project onto this browser's display. Resolve
        // every covering output just as Settings and connection sheets do.
        if let onRevealControls { onRevealControls(window) }
        else if fullscreenDisplayID == window?.screen.map(DisplayCatalog.identifier) { fullscreen.showControls() }
        window?.makeKeyAndOrderFront(nil); sourceBrowser.focusSelectedSource()
    }
    @objc func showTestPattern(_ sender: Any?) { connect(.testPattern) }
    @objc func connectAddress(_ sender: Any?) {
        guard let window else { return }
        if let onRevealControls { onRevealControls(window) }
        else if fullscreenDisplayID == window.screen.map(DisplayCatalog.identifier) { fullscreen.showControls() }
        window.makeKeyAndOrderFront(nil)
        let alert = NSAlert(); alert.messageText = "Connect to OMT Source"; alert.informativeText = "Enter the sender’s address and TCP port."
        alert.addButton(withTitle: "Connect"); alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24)); input.placeholderString = "omt://192.168.1.20:6400"
        input.setAccessibilityLabel("OMT source address"); alert.accessoryView = input; alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                let source = try OMTSource.manual(input.stringValue)
                if !self.manualSources.contains(source) { self.manualSources.append(source) }
                self.connect(source)
            } catch { self.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil) }
        }
    }
    func shutdown(completion: @escaping @MainActor @Sendable () -> Void) {
        shutdownCompletions.append(completion)
        if shutdownFinished { finishShutdown(); return }
        guard !closed else { return }
        closed = true
        fullscreen.exit(showOwner: false)
        session.disconnect(); audio.stop(); video.clear(); video.isPaused = true
        let group = DispatchGroup()
        group.enter(); session.stop { group.leave() }
        group.enter(); sourceBrowser.stop { group.leave() }
        group.notify(queue: .main) { [self] in shutdownFinished = true; finishShutdown() }
    }
    private func finishShutdown() {
        let completions = shutdownCompletions; shutdownCompletions.removeAll(); completions.forEach { $0() }
    }
    func windowWillClose(_ notification: Notification) {
        if let window, !window.frameAutosaveName.isEmpty {
            window.saveFrame(usingName: window.frameAutosaveName)
            // Closing does not release AppKit's name registration while this
            // window is still retained during asynchronous receiver retirement.
            window.setFrameAutosaveName("")
        }
        // The frame slot is reusable as soon as the native window closes;
        // keep asynchronous media retirement on its separate completion path.
        let windowWillClose = onWindowWillClose
        onWindowWillClose = nil
        windowWillClose?(self)
        shutdown { [self] in onClose?(self) }
    }
    func owns(_ candidate: NSWindow?) -> Bool { candidate.map { window === $0 || fullscreen?.owns($0) == true } ?? false }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) + [.receiverUpdate] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.receiverSidebar, .flexibleSpace, .receiverMute, .receiverReconnect, .receiverFullscreen] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier); item.target = self
        switch identifier {
        case .receiverSidebar: item.label = "Sources"; item.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Show Sources"); item.action = #selector(toggleSidebar)
        case .receiverMute: item.label = "Mute"; item.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "Mute Output Audio"); item.action = #selector(toggleMute)
        case .receiverReconnect: item.label = "Reconnect"; item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reconnect"); item.action = #selector(reconnect)
        case .receiverFullscreen: item.label = "Fullscreen"; item.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Open Source Fullscreen"); item.action = #selector(toggleFullscreen)
        case .receiverUpdate: item.action = #selector(showUpdate); renderUpdateBadge(item)
        default: return nil
        }
        if identifier != .receiverUpdate { item.toolTip = item.label }
        return item
    }
    deinit {
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
        if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) }
    }
}
