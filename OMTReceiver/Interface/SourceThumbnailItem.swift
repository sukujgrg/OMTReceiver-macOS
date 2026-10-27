import AppKit

@MainActor
final class SourceThumbnailItem: NSCollectionViewItem {
    var sourceID: String?
    var card: SourceThumbnailCard { view as! SourceThumbnailCard }
    override func loadView() { view = SourceThumbnailCard() }
    override var isSelected: Bool { didSet { if isViewLoaded { card.isSelected = isSelected } } }
    override func prepareForReuse() {
        super.prepareForReuse()
        sourceID = nil
        card.onActivate = nil
        card.detachPreview()
    }
}

@MainActor
final class SourceThumbnailCard: NSButton {
    var onActivate: (() -> Void)?
    var isSelected = false { didSet { if oldValue != isSelected { updateAppearance() } } }
    private let previewHost = NSView()
    private let placeholder = NSImageView(image: NSImage(systemSymbolName: "video", accessibilityDescription: nil) ?? NSImage())
    private let name = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let playing = NSTextField(labelWithString: "Playing")
    private weak var preview: NSView?

    init() {
        super.init(frame: .zero)
        // AppKit owns press tracking: release inside commits, dragging outside
        // cancels, and subsequent clicks of a double click are ignored.
        setButtonType(.momentaryPushIn)
        title = ""
        isBordered = false
        isTransparent = true
        ignoresMultiClick = true
        isContinuous = false
        sendAction(on: .leftMouseUp)
        target = self
        action = #selector(activateSource)
        wantsLayer = true
        layer?.cornerRadius = 8; layer?.borderWidth = 1; layer?.masksToBounds = true
        previewHost.wantsLayer = true
        previewHost.layer?.backgroundColor = NSColor.black.cgColor
        placeholder.contentTintColor = .secondaryLabelColor
        placeholder.imageScaling = .scaleProportionallyDown
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        playing.font = .systemFont(ofSize: 10, weight: .semibold)
        playing.textColor = .systemGreen
        playing.setContentHuggingPriority(.required, for: .horizontal)
        playing.setContentCompressionResistancePriority(.required, for: .horizontal)
        for child in [previewHost, name, status, playing] {
            child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child)
        }
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        previewHost.addSubview(placeholder)
        NSLayoutConstraint.activate([
            previewHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewHost.topAnchor.constraint(equalTo: topAnchor),
            previewHost.heightAnchor.constraint(equalTo: previewHost.widthAnchor, multiplier: 9.0 / 16.0),
            placeholder.centerXAnchor.constraint(equalTo: previewHost.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: previewHost.centerYAnchor),
            placeholder.widthAnchor.constraint(equalToConstant: 30), placeholder.heightAnchor.constraint(equalToConstant: 24),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            name.topAnchor.constraint(equalTo: previewHost.bottomAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: playing.leadingAnchor, constant: -8),
            playing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            playing.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            status.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 5),
            status.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityEnabled(true)
        setAccessibilityHelp("Click or press Return to open this source fullscreen on the configured display.")
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError("Use init()") }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    func configure(source: OMTSource, status state: String, format: String,
                   isPlaying: Bool, preview surface: NSView?) {
        if name.stringValue != source.name { name.stringValue = source.name }
        let description = format.isEmpty ? state : "\(state) · \(format)"
        if status.stringValue != description { status.stringValue = description }
        status.toolTip = description
        if playing.isHidden == isPlaying { playing.isHidden = !isPlaying }
        toolTip = "\(source.name)\n\(source.address)\n\(description)"
        setAccessibilityLabel(source.name)
        let value = (isPlaying ? "Playing fullscreen. " : "") + description
        if accessibilityValue() as? String != value {
            setAccessibilityValue(value)
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
        if let surface {
            if let existing = preview, existing !== surface { detachPreview() }
            if surface.superview !== previewHost {
                surface.removeFromSuperview()
                surface.translatesAutoresizingMaskIntoConstraints = false
                previewHost.addSubview(surface)
                NSLayoutConstraint.activate([
                    surface.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor),
                    surface.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor),
                    surface.topAnchor.constraint(equalTo: previewHost.topAnchor),
                    surface.bottomAnchor.constraint(equalTo: previewHost.bottomAnchor)
                ])
            }
            preview = surface
        } else { detachPreview() }
        if placeholder.isHidden != (surface != nil) { placeholder.isHidden = surface != nil }
    }

    func detachPreview() {
        if preview?.superview === previewHost { preview?.removeFromSuperview() }
        preview = nil
        if placeholder.isHidden { placeholder.isHidden = false }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        return self
    }
    @objc private func activateSource(_ sender: Any?) { onActivate?() }
    override func resetCursorRects() { super.resetCursorRects(); addCursorRect(bounds, cursor: .pointingHand) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }
    private func updateAppearance() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = (isSelected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.borderWidth = isSelected ? 2 : 1
    }
}
