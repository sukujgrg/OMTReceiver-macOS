import AppKit

@MainActor
final class PreferencesWindowController: NSWindowController {
    private let displays = NSPopUpButton()
    private let deinterlace = NSPopUpButton()
    private let fields = NSPopUpButton()
    private let background = NSPopUpButton()
    private let server = NSTextField()
    private let networkStatus = NSTextField(wrappingLabelWithString: "Leave blank to use Bonjour on the local network. Changes to the discovery server take effect after relaunch.")
    private var displayObserver: NSObjectProtocol?
    private var updateObserver: NSObjectProtocol?
    private let updates: AppUpdateViewModel?
    private let automaticUpdates = NSButton(checkboxWithTitle: "Automatically Check for Updates", target: nil, action: nil)
    private let checkUpdates = NSButton(title: "Check for Updates…", target: nil, action: nil)
    private let updateStatus = NSTextField(wrappingLabelWithString: "")
    private let discovery: OMTDiscoveryManager

    init(discovery: OMTDiscoveryManager, updates: AppUpdateViewModel? = nil) {
        self.discovery = discovery; self.updates = updates
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "OMTReceiver Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        if let updates {
            updateObserver = NotificationCenter.default.addObserver(forName: .receiverUpdateStateChanged, object: updates, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.renderUpdates() }
            }
        }
        renderUpdates()
        window.center()
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadDisplays() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func build() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)])
        stack.addArrangedSubview(section("Display"))
        displays.target = self; displays.action = #selector(displayChanged)
        displays.setAccessibilityLabel("Default fullscreen display")
        stack.addArrangedSubview(row("Fullscreen on:", displays))
        stack.addArrangedSubview(note("Click a live source thumbnail, or press ⌃⌘F, to open output on this display. Escape stops output and returns focus to sources. Changing this selection moves active fullscreen views immediately. A disconnected display falls back to the main display on the next fullscreen request."))
        stack.addArrangedSubview(section("Playback"))
        configure(deinterlace, titles: DeinterlaceMode.allCases.map(\.title), selected: DeinterlaceMode.allCases.firstIndex(of: Preferences.shared.deinterlace) ?? 0, action: #selector(playbackChanged))
        configure(fields, titles: FieldOrder.allCases.map(\.title), selected: FieldOrder.allCases.firstIndex(of: Preferences.shared.fieldOrder) ?? 0, action: #selector(playbackChanged))
        configure(background, titles: VideoBackground.allCases.map(\.title), selected: VideoBackground.allCases.firstIndex(of: Preferences.shared.background) ?? 0, action: #selector(playbackChanged))
        stack.addArrangedSubview(row("Interlaced video:", deinterlace))
        stack.addArrangedSubview(row("Field order:", fields))
        stack.addArrangedSubview(row("Alpha background:", background))
        stack.addArrangedSubview(section("Network"))
        server.stringValue = Preferences.shared.discoveryServer
        server.placeholderString = "omt://discovery-server:6399"
        server.setAccessibilityLabel("OMT discovery server address")
        server.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        let apply = NSButton(title: "Apply", target: self, action: #selector(applyServer))
        let serverRow = NSStackView(views: [server, apply]); serverRow.spacing = 8
        serverRow.distribution = .fill
        stack.addArrangedSubview(row("Discovery server:", serverRow))
        networkStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        networkStatus.textColor = .secondaryLabelColor
        stack.addArrangedSubview(networkStatus)
        networkStatus.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(section("Updates"))
        automaticUpdates.target = self; automaticUpdates.action = #selector(automaticUpdatesChanged)
        automaticUpdates.setAccessibilityLabel("Automatically Check for Updates")
        checkUpdates.target = self; checkUpdates.action = #selector(checkUpdatesPressed)
        checkUpdates.bezelStyle = .rounded
        checkUpdates.setAccessibilityLabel("Check for Updates")
        stack.addArrangedSubview(row("", automaticUpdates))
        stack.addArrangedSubview(row("", checkUpdates))
        updateStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        updateStatus.textColor = .secondaryLabelColor
        updateStatus.setAccessibilityLabel("Update status")
        stack.addArrangedSubview(updateStatus)
        updateStatus.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24).isActive = true
        reloadDisplays()
    }
    private func renderUpdates() {
        automaticUpdates.state = updates?.automaticallyChecksForUpdates == true ? .on : .off
        automaticUpdates.isEnabled = updates != nil
        checkUpdates.isEnabled = updates?.canCheckForUpdates == true
        if let error = updates?.startupError {
            updateStatus.stringValue = error; updateStatus.textColor = .systemRed
        } else {
            updateStatus.textColor = .secondaryLabelColor
            if let version = updates?.availableVersion {
                updateStatus.stringValue = "OMTReceiver \(version) is available. " + (updates?.canCheckForUpdates == true ? "You choose when to download and install." : "Update controls are temporarily unavailable.")
            } else {
                updateStatus.stringValue = updates == nil ? "Updates are unavailable in this session." : "Checks run in the background. You choose when to download and install."
            }
        }
    }
    @objc private func automaticUpdatesChanged(_ sender: NSButton) { updates?.setAutomaticChecks(sender.state == .on) }
    @objc private func checkUpdatesPressed(_ sender: Any?) { updates?.checkForUpdates() }
    private func section(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text); label.font = .boldSystemFont(ofSize: NSFont.systemFontSize); return label
    }
    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: NSFont.smallSystemFontSize); label.textColor = .secondaryLabelColor; label.preferredMaxLayoutWidth = 530; return label
    }
    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let row = NSStackView(views: [label, control]); row.spacing = 12; row.alignment = .centerY
        return row
    }
    private func configure(_ popup: NSPopUpButton, titles: [String], selected: Int, action: Selector) {
        popup.addItems(withTitles: titles); popup.selectItem(at: selected); popup.target = self; popup.action = action
    }
    private func reloadDisplays() {
        displays.removeAllItems()
        let main = NSMenuItem(title: "Main Display", action: nil, keyEquivalent: ""); main.representedObject = ""
        displays.menu?.addItem(main)
        for screen in NSScreen.screens {
            let id = DisplayCatalog.identifier(for: screen)
            let item = NSMenuItem(title: "\(screen.localizedName) — \(Int(screen.frame.width)) × \(Int(screen.frame.height))", action: nil, keyEquivalent: "")
            item.representedObject = id; displays.menu?.addItem(item)
        }
        let saved = Preferences.shared.fullscreenDisplayID
        if let item = displays.itemArray.first(where: { ($0.representedObject as? String) == saved }) { displays.select(item) }
        else {
            let item = NSMenuItem(title: "Saved Display (Disconnected)", action: nil, keyEquivalent: "")
            item.representedObject = saved; item.isEnabled = false
            displays.menu?.addItem(item); displays.select(item)
        }
    }
    @objc private func displayChanged() { Preferences.shared.fullscreenDisplayID = displays.selectedItem?.representedObject as? String ?? "" }
    @objc private func playbackChanged() {
        Preferences.shared.deinterlace = DeinterlaceMode.allCases[deinterlace.indexOfSelectedItem]
        Preferences.shared.fieldOrder = FieldOrder.allCases[fields.indexOfSelectedItem]
        Preferences.shared.background = VideoBackground.allCases[background.indexOfSelectedItem]
    }
    @objc private func applyServer() {
        let address = server.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let validated = address.isEmpty ? "" : try OMTSource.manual(address).address
            Preferences.shared.discoveryServer = validated
            discovery.configure(server: validated)
            networkStatus.stringValue = discovery.requiresRestart ? "Saved. Quit and reopen OMTReceiver to use this discovery setting." : "Saved. Bonjour discovery is available on the local network."
            networkStatus.textColor = .secondaryLabelColor
        } catch {
            networkStatus.stringValue = error.localizedDescription
            networkStatus.textColor = .systemRed
            window?.makeFirstResponder(server)
        }
    }
    deinit {
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) }
    }
}
