import AppKit

@main
@MainActor
enum OMTReceiverApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let discovery = OMTDiscoveryManager()
    private let updates = AppUpdateViewModel(driver: SparkleUpdateDriver())
    private let windowContext: @MainActor () -> (key: NSWindow?, main: NSWindow?)
    private var receivers: [ReceiverWindowController] = []
    private var settings: PreferencesWindowController?
    private var nextWindowNumber = 1
    private var terminating = false
    private var testHost: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil }
    init(windowContext: @escaping @MainActor () -> (key: NSWindow?, main: NSWindow?) = { (NSApp.keyWindow, NSApp.mainWindow) }) {
        self.windowContext = windowContext
        super.init()
    }
    private var activeReceiver: ReceiverWindowController? {
        let context = windowContext()
        return Self.receiver(keyWindow: context.key, mainWindow: context.main, receivers: receivers)
    }
    static func receiver(keyWindow: NSWindow?, mainWindow: NSWindow?, receivers: [ReceiverWindowController]) -> ReceiverWindowController? {
        // Settings and other non-receiver key windows have no implicit media
        // target. Never mute/disconnect an unrelated window through a fallback.
        if let keyWindow { return receivers.first { $0.owns(keyWindow) } }
        return receivers.first { $0.owns(mainWindow) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenus()
        guard !testHost else { return }
        updates.start()
        discovery.configure(server: Preferences.shared.discoveryServer)
        discovery.onChange = { [weak self] in self?.receivers.forEach { $0.refreshDiscovery() } }
        discovery.start()
        newReceiver(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newReceiver(nil) }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !testHost else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        let group = DispatchGroup()
        for controller in receivers {
            group.enter()
            controller.shutdown { group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            self?.discovery.stop {
                DispatchQueue.global(qos: .userInitiated).async {
                    OMTSDKRuntime.shared.shutdown()
                    DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
                }
            }
        }
        return .terminateLater
    }
    @objc func newReceiver(_ sender: Any?) {
        guard !terminating else { return }
        let receiver = ReceiverWindowController(discovery: discovery, number: nextWindowNumber, updates: updates)
        nextWindowNumber += 1
        receiver.onClose = { [weak self] closed in self?.receivers.removeAll { $0 === closed } }
        receiver.onCheckForUpdates = { [weak self] window in self?.presentUpdateDialog(from: window) }
        receiver.onRevealControls = { [weak self] window in
            guard let self else { return }
            Self.revealControls(for: window, receivers: self.receivers)
        }
        receivers.append(receiver)
        receiver.showWindow(nil)
    }
    @objc func showSettings(_ sender: Any?) {
        let invoking = receivers.first { $0.owns(NSApp.keyWindow) }
        Self.revealControls(for: NSApp.keyWindow, receivers: receivers)
        if settings == nil { settings = PreferencesWindowController(discovery: discovery, updates: updates) }
        if let screen = invoking?.window?.screen, let panel = settings?.window,
           panel.screen.map(DisplayCatalog.identifier) != DisplayCatalog.identifier(for: screen) {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2,
                                         y: visible.midY - panel.frame.height / 2))
        }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }
    /// Present native controls on the browser's display. Output on another
    /// display keeps playing while Settings or the updater is open.
    static func revealControls(for keyWindow: NSWindow?, receivers: [ReceiverWindowController]) {
        guard let invoking = receivers.first(where: { $0.owns(keyWindow) }) else { return }
        let controlsDisplay = invoking.window?.screen.map(DisplayCatalog.identifier)
        for receiver in receivers where receiver.fullscreenDisplayID != nil && receiver.fullscreenDisplayID == controlsDisplay {
            receiver.revealControlsForDialog()
        }
        invoking.window?.makeKeyAndOrderFront(nil)
        invoking.sourceBrowser.focusSelectedSource()
    }
    @objc private func checkForUpdates(_ sender: Any?) { presentUpdateDialog(from: NSApp.keyWindow) }
    private func presentUpdateDialog(from window: NSWindow?) {
        guard updates.canCheckForUpdates else { return }
        Self.revealControls(for: window, receivers: receivers)
        updates.checkForUpdates()
    }
    @objc private func connectAddress(_ sender: Any?) { ensureReceiver().connectAddress(sender) }
    @objc private func testPattern(_ sender: Any?) { ensureReceiver().showTestPattern(sender) }
    @objc private func toggleFullscreen(_ sender: Any?) { activeReceiver?.toggleFullscreen(sender) }
    @objc private func toggleMute(_ sender: Any?) { activeReceiver?.toggleMute(sender) }
    @objc private func reconnect(_ sender: Any?) { activeReceiver?.reconnect(sender) }
    @objc private func disconnect(_ sender: Any?) { activeReceiver?.disconnect(sender) }
    @objc private func toggleSidebar(_ sender: Any?) { activeReceiver?.toggleSidebar(sender) }
    @objc private func closeWindow(_ sender: Any?) { Self.close(window: NSApp.keyWindow, receivers: receivers, sender: sender) }
    static func close(window: NSWindow?, receivers: [ReceiverWindowController], sender: Any? = nil) {
        guard let window else { return }
        // A borderless output has no standard close button for performClose.
        // Close its owned presentation while preserving the source browser.
        if let receiver = receivers.first(where: { $0.owns(window) }), window !== receiver.window {
            receiver.disconnect(sender)
        } else { window.performClose(sender) }
    }
    private func ensureReceiver() -> ReceiverWindowController {
        if let receiver = activeReceiver { return receiver }
        newReceiver(nil)
        return receivers.last!
    }
    @objc private func showHelp(_ sender: Any?) {
        guard let url = Bundle.main.url(forResource: "Help", withExtension: "html") else { return }
        NSWorkspace.shared.open(url)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard !terminating else { return false }
        switch menuItem.action {
        case #selector(checkForUpdates): return updates.canCheckForUpdates
        case #selector(toggleFullscreen): menuItem.title = activeReceiver?.isFullscreen == true ? "Exit Full Screen" : "Enter Full Screen"; return activeReceiver != nil
        case #selector(toggleMute): menuItem.state = activeReceiver?.muted == true ? .on : .off; return activeReceiver != nil
        case #selector(reconnect), #selector(disconnect): return activeReceiver?.selectedSource != nil
        case #selector(toggleSidebar): return activeReceiver != nil
        case #selector(closeWindow): return NSApp.keyWindow != nil
        default: return true
        }
    }
    func makeMenus() {
        let bar = NSMenu()
        NSApp.mainMenu = bar
        let app = submenu("OMTReceiver", in: bar)
        add("About OMTReceiver", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), to: app, target: NSApp)
        app.addItem(.separator())
        add("Settings…", #selector(showSettings), key: ",", to: app)
        add("Check for Updates…", #selector(checkForUpdates), to: app)
        app.addItem(.separator())
        let services = submenu("Services", in: app); NSApp.servicesMenu = services
        app.addItem(.separator())
        add("Hide OMTReceiver", #selector(NSApplication.hide(_:)), key: "h", to: app, target: NSApp)
        add("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option], to: app, target: NSApp)
        add("Show All", #selector(NSApplication.unhideAllApplications(_:)), to: app, target: NSApp)
        app.addItem(.separator())
        add("Quit OMTReceiver", #selector(NSApplication.terminate(_:)), key: "q", to: app, target: NSApp)
        let file = submenu("File", in: bar)
        add("New Receiver Window", #selector(newReceiver), key: "n", to: file)
        add("Connect to Address…", #selector(connectAddress), key: "o", to: file)
        add("Open Test Pattern", #selector(testPattern), key: "t", modifiers: [.command, .option], to: file)
        file.addItem(.separator())
        add("Close Window", #selector(closeWindow), key: "w", to: file)
        let edit = submenu("Edit", in: bar)
        add("Undo", Selector(("undo:")), key: "z", to: edit, responder: true)
        add("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift], to: edit, responder: true)
        edit.addItem(.separator())
        add("Cut", #selector(NSText.cut(_:)), key: "x", to: edit, responder: true)
        add("Copy", #selector(NSText.copy(_:)), key: "c", to: edit, responder: true)
        add("Paste", #selector(NSText.paste(_:)), key: "v", to: edit, responder: true)
        add("Select All", #selector(NSText.selectAll(_:)), key: "a", to: edit, responder: true)
        let view = submenu("View", in: bar)
        add("Show Sources", #selector(toggleSidebar), key: "s", modifiers: [.command, .option], to: view)
        view.addItem(.separator())
        add("Enter Full Screen", #selector(toggleFullscreen), key: "f", modifiers: [.command, .control], to: view)
        let playback = submenu("Playback", in: bar)
        add("Mute Audio", #selector(toggleMute), key: "m", modifiers: [.command, .shift], to: playback)
        playback.addItem(.separator())
        add("Reconnect", #selector(reconnect), key: "r", to: playback)
        add("Stop Output", #selector(disconnect), key: "d", modifiers: [.command, .shift], to: playback)
        let window = submenu("Window", in: bar); NSApp.windowsMenu = window
        add("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m", to: window, responder: true)
        add("Zoom", #selector(NSWindow.performZoom(_:)), to: window, responder: true)
        window.addItem(.separator())
        add("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), to: window, target: NSApp)
        let help = submenu("Help", in: bar); NSApp.helpMenu = help
        add("OMTReceiver Help", #selector(showHelp), key: "?", to: help)
    }
    private func submenu(_ title: String, in parent: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title); item.submenu = menu; parent.addItem(item); return menu
    }
    private func add(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command, to menu: NSMenu, target: AnyObject? = nil, responder: Bool = false) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = responder ? nil : (target ?? self)
        menu.addItem(item)
    }
}
