import AppKit

/// NSWindow's explicit-screen initializer interprets contentRect in that
/// screen's coordinates. Passing screen.frame would add its origin twice.
final class PresentationWindow: NSWindow {
    convenience init(on screen: NSScreen) {
        self.init(contentRect: DisplayCatalog.screenRelativeContentRect(for: screen.frame),
                   styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        isReleasedWhenClosed = false
        isRestorable = false
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        // Match the native projection window used by eucaly. The selected
        // display can contain another application's fullscreen Space.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns a dedicated native borderless window, preserving the receiver's normal geometry.
@MainActor
final class FullscreenController: NSObject, NSWindowDelegate {
    private static var activeOwners = Set<ObjectIdentifier>()
    private static var originalPresentationOptions: NSApplication.PresentationOptions = []
    private weak var owner: NSWindow?
    private weak var home: NSView?
    private let video: VideoView
    private let screens: () -> [NSScreen]
    private let keepOwnerVisible: Bool
    var restoreOwnerFocus: (() -> Void)?
    private var presentation: PresentationWindow?
    private var targetID = ""
    private var requestedDisplayID = ""
    private var originalExcludedFromWindowsMenu = false
    private var displayObserver: NSObjectProtocol?
    private var preferenceObserver: NSObjectProtocol?
    var isFullscreen: Bool { presentation != nil }
    private(set) var isRetargeting = false
    var onChange: (() -> Void)?

    init(owner: NSWindow, home: NSView, video: VideoView, keepOwnerVisible: Bool = false, screens: @escaping () -> [NSScreen] = { NSScreen.screens }) {
        self.owner = owner; self.home = home; self.video = video; self.keepOwnerVisible = keepOwnerVisible; self.screens = screens
        super.init()
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        preferenceObserver = NotificationCenter.default.addObserver(forName: .receiverPreferencesChanged, object: Preferences.shared, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferenceChanged() }
        }
    }
    func owns(_ window: NSWindow) -> Bool { presentation === window }
    func toggle() { isFullscreen ? exit() : enter() }
    func enter() {
        guard presentation == nil, let screen = DisplayCatalog.target(identifier: Preferences.shared.fullscreenDisplayID, screens: screens()) else { return }
        requestedDisplayID = Preferences.shared.fullscreenDisplayID
        targetID = DisplayCatalog.identifier(for: screen)
        // The window must already belong to the target screen when MetalKit's
        // viewDidMoveToWindow runs; correcting an offscreen frame afterward is
        // too late for the view's initial display-link/drawable association.
        let window = PresentationWindow(on: screen)
        window.title = owner?.title ?? "OMTReceiver"
        window.delegate = self
        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.contentView = host
        video.removeFromSuperview()
        pin(video, to: host)
        host.layoutSubtreeIfNeeded()
        presentation = window
        originalExcludedFromWindowsMenu = owner?.isExcludedFromWindowsMenu ?? false
        owner?.isExcludedFromWindowsMenu = keepOwnerVisible ? originalExcludedFromWindowsMenu : true
        if Self.activeOwners.isEmpty { Self.originalPresentationOptions = NSApp.presentationOptions }
        Self.activeOwners.insert(ObjectIdentifier(self))
        var options = Self.originalPresentationOptions
        options.subtract([.hideDock, .hideMenuBar, .autoHideDock, .autoHideMenuBar])
        options.formUnion([.autoHideDock, .autoHideMenuBar])
        NSApp.presentationOptions = options
        window.setFrame(screen.frame, display: true)
        if keepOwnerVisible, let ownerScreen = owner?.screen,
           DisplayCatalog.identifier(for: ownerScreen) != targetID {
            // Keep the source grid usable on the controls display while output
            // fills another display. Clicking the output can still make it key.
            window.orderFront(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(video)
        }
        if !keepOwnerVisible { owner?.orderOut(nil) }
        onChange?()
    }
    func exit(showOwner: Bool = true) {
        guard let window = presentation else { return }
        presentation = nil
        window.delegate = nil
        video.removeFromSuperview()
        if let home { pin(video, to: home); home.layoutSubtreeIfNeeded() }
        window.orderOut(nil)
        window.close()
        owner?.isExcludedFromWindowsMenu = originalExcludedFromWindowsMenu
        Self.activeOwners.remove(ObjectIdentifier(self))
        if Self.activeOwners.isEmpty { NSApp.presentationOptions = Self.originalPresentationOptions }
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
        window.contentView?.layoutSubtreeIfNeeded()
    }
    private func preferenceChanged() {
        guard presentation != nil, requestedDisplayID != Preferences.shared.fullscreenDisplayID else { return }
        // Retargeting is a view transfer, not a user stop command.
        isRetargeting = true
        exit(showOwner: false)
        enter()
        isRetargeting = false
        if presentation == nil { onChange?() }
    }
    private func pin(_ view: NSView, to parent: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: parent.leadingAnchor), view.trailingAnchor.constraint(equalTo: parent.trailingAnchor), view.topAnchor.constraint(equalTo: parent.topAnchor), view.bottomAnchor.constraint(equalTo: parent.bottomAnchor)])
    }
    deinit {
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
    }
}
