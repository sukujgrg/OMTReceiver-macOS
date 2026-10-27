import AppKit

/// A full-quality output is an ongoing user-requested presentation, including
/// while its controls are visible. Releasing this scope restores ordinary idle
/// sleep/App Nap policy; browsing thumbnails alone never creates an activity.
final class FullscreenPlaybackActivity {
    private let token = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .idleDisplaySleepDisabled],
        reason: "Receiving fullscreen OMT video and audio")

    deinit { ProcessInfo.processInfo.endActivity(token) }
}

/// NSWindow's explicit-screen initializer interprets contentRect in that
/// screen's coordinates. Passing screen.frame would add its origin twice.
final class PresentationWindow: NSWindow {
    enum Role { case viewer, projection }
    convenience init(on screen: NSScreen, role: Role = .projection) {
        self.init(contentRect: DisplayCatalog.screenRelativeContentRect(for: screen.frame),
                   styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        isReleasedWhenClosed = false
        isRestorable = false
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        // External projection must survive switching control apps/Spaces.
        // Same-screen viewing must yield normally when another app activates.
        level = role == .projection ? .screenSaver : .normal
        collectionBehavior = role == .projection ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenNone]
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns a dedicated native borderless window, preserving the receiver's normal geometry.
@MainActor
final class FullscreenController: NSObject, NSWindowDelegate {
    private final class Owner {
        weak var controller: FullscreenController?
        init(_ controller: FullscreenController) { self.controller = controller }
    }
    // A physical display has one output owner. Replacing it retires the old
    // controller through its ordinary exit notification, including its audio.
    private static var owners: [String: Owner] = [:]
    private static var originalPresentationOptions: NSApplication.PresentationOptions = []
    private weak var owner: NSWindow?
    private weak var home: NSView?
    private let video: VideoView
    private let screens: () -> [NSScreen]
    private let safeAreaInsets: (NSScreen) -> NSEdgeInsets
    private let keyWindow: @MainActor () -> NSWindow?
    private let activityFactory: () -> AnyObject
    private var playbackActivity: AnyObject?
    private let keepOwnerVisible: Bool
    var restoreOwnerFocus: (() -> Void)?
    private var presentation: PresentationWindow?
    private var surfaceConstraints: [NSLayoutConstraint] = []
    private enum Intent { case output, controls }
    private var intent = Intent.output
    private var targetID = ""
    private var requestedDisplayID = ""
    private var originalExcludedFromWindowsMenu = false
    private var displayObserver: NSObjectProtocol?
    private var preferenceObserver: NSObjectProtocol?
    private var ownerScreenObserver: NSObjectProtocol?
    var isFullscreen: Bool { presentation != nil }
    private(set) var isRetargeting = false
    var onChange: (() -> Void)?

    init(owner: NSWindow, home: NSView, video: VideoView, keepOwnerVisible: Bool = false, screens: @escaping () -> [NSScreen] = { NSScreen.screens },
         safeAreaInsets: @escaping (NSScreen) -> NSEdgeInsets = { $0.safeAreaInsets },
         keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow },
         activityFactory: @escaping () -> AnyObject = { FullscreenPlaybackActivity() }) {
        self.owner = owner; self.home = home; self.video = video; self.keepOwnerVisible = keepOwnerVisible; self.screens = screens; self.safeAreaInsets = safeAreaInsets; self.keyWindow = keyWindow; self.activityFactory = activityFactory
        super.init()
        ownerScreenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: owner, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, let window = self.presentation { self.applyPolicy(to: window) } }
        }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        preferenceObserver = NotificationCenter.default.addObserver(forName: .receiverPreferencesChanged, object: Preferences.shared, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferenceChanged() }
        }
    }
    func owns(_ window: NSWindow) -> Bool { presentation === window }
    func toggle() { isFullscreen ? exit() : enter() }
    func enter(preservingControls controls: NSWindow? = nil) {
        if let presentation { present(presentation, preservingControls: controls); return }
        guard let screen = DisplayCatalog.target(identifier: Preferences.shared.fullscreenDisplayID, screens: screens()) else { return }
        requestedDisplayID = Preferences.shared.fullscreenDisplayID
        targetID = DisplayCatalog.identifier(for: screen)
        // Acquire the replacement's scope before retiring a displaced output.
        // A display handoff must not briefly restore idle policy.
        if playbackActivity == nil { playbackActivity = activityFactory() }
        Self.owners = Self.owners.filter { $0.value.controller?.isFullscreen == true }
        Self.owners[targetID]?.controller?.exit(showOwner: false)
        // The window must already belong to the target screen when MetalKit's
        // viewDidMoveToWindow runs; correcting an offscreen frame afterward is
        // too late for the view's initial display-link/drawable association.
        let isExternal = owner?.screen.map(DisplayCatalog.identifier) != targetID
        let window = PresentationWindow(on: screen, role: isExternal ? .projection : .viewer)
        window.title = owner?.title ?? "OMTReceiver"
        window.delegate = self
        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.contentView = host
        video.removeFromSuperview()
        pin(video, to: host, insets: safeAreaInsets(screen))
        host.layoutSubtreeIfNeeded()
        presentation = window
        originalExcludedFromWindowsMenu = owner?.isExcludedFromWindowsMenu ?? false
        owner?.isExcludedFromWindowsMenu = keepOwnerVisible ? originalExcludedFromWindowsMenu : true
        if Self.owners.isEmpty { Self.originalPresentationOptions = NSApp.presentationOptions }
        Self.owners[targetID] = Owner(self)
        var options = Self.originalPresentationOptions
        options.subtract([.hideDock, .hideMenuBar, .autoHideDock, .autoHideMenuBar])
        options.formUnion([.autoHideDock, .autoHideMenuBar])
        NSApp.presentationOptions = options
        window.setFrame(screen.frame, display: true)
        present(window, preservingControls: controls)
        if !keepOwnerVisible { owner?.orderOut(nil) }
        onChange?()
    }
    private func present(_ window: PresentationWindow, preservingControls controls: NSWindow?) {
        intent = controls?.screen.map(DisplayCatalog.identifier) == targetID ? .controls : .output
        applyPolicy(to: window)
        if intent == .controls, let controls {
            window.order(.below, relativeTo: controls.windowNumber)
            controls.makeKeyAndOrderFront(nil)
            return
        }
        let isExternal = intent == .output && owner?.screen.map(DisplayCatalog.identifier) != targetID
        if keepOwnerVisible && isExternal { window.orderFront(nil) }
        else {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(video)
        }
    }
    private func applyPolicy(to window: PresentationWindow) {
        let isExternal = intent == .output && owner?.screen.map(DisplayCatalog.identifier) != targetID
        window.level = isExternal ? .screenSaver : .normal
        window.collectionBehavior = isExternal ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenNone]
    }
    /// Native dialogs change window order, never receiver lifetime. Returning
    /// to a thumbnail raises this same output with its picture/audio intact.
    func showControls() {
        guard let owner else { return }
        intent = .controls
        if let presentation {
            applyPolicy(to: presentation)
            presentation.order(.below, relativeTo: owner.windowNumber)
        }
        owner.makeKeyAndOrderFront(nil)
        restoreOwnerFocus?()
    }
    func updateTitle(_ title: String) { presentation?.title = title }
    func exit(showOwner: Bool = true) {
        guard let window = presentation else { return }
        presentation = nil
        intent = .output
        window.delegate = nil
        video.removeFromSuperview()
        if let home { pin(video, to: home); home.layoutSubtreeIfNeeded() }
        window.orderOut(nil)
        window.close()
        if !isRetargeting { playbackActivity = nil }
        owner?.isExcludedFromWindowsMenu = originalExcludedFromWindowsMenu
        if Self.owners[targetID]?.controller === self { Self.owners.removeValue(forKey: targetID) }
        if Self.owners.isEmpty { NSApp.presentationOptions = Self.originalPresentationOptions }
        if showOwner {
            owner?.makeKeyAndOrderFront(nil)
            if let restoreOwnerFocus { restoreOwnerFocus() }
            else { owner?.makeFirstResponder(video) }
        }
        onChange?()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { exit(); return false }
    private func screensChanged() {
        guard let window = presentation else { return }
        guard let screen = screens().first(where: { DisplayCatalog.identifier(for: $0) == targetID }) else {
            // Returning to the normal window prevents accidental output on an unintended display.
            exit(); return
        }
        window.setFrame(screen.frame, display: true)
        if let host = window.contentView { pin(video, to: host, insets: safeAreaInsets(screen)) }
        window.contentView?.layoutSubtreeIfNeeded()
    }
    private func preferenceChanged() {
        guard presentation != nil, requestedDisplayID != Preferences.shared.fullscreenDisplayID else { return }
        let controls = keyWindow().flatMap { $0 === presentation ? nil : $0 }
        // Retargeting is a view transfer, not a user stop command.
        isRetargeting = true
        exit(showOwner: false)
        enter(preservingControls: controls)
        isRetargeting = false
        if presentation == nil { playbackActivity = nil; onChange?() }
    }
    private func pin(_ view: NSView, to parent: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        NSLayoutConstraint.deactivate(surfaceConstraints)
        view.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(view)
        surfaceConstraints = [view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -insets.right),
            view.topAnchor.constraint(equalTo: parent.topAnchor, constant: insets.top),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -insets.bottom)]
        NSLayoutConstraint.activate(surfaceConstraints)
    }
    deinit {
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
        if let ownerScreenObserver { NotificationCenter.default.removeObserver(ownerScreenObserver) }
    }
}
