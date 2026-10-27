import AppKit

/// The normal receiver window is a live source browser. Selecting with the
/// keyboard is private; one click, Return or Space explicitly opens a source.
@MainActor
final class SourceBrowserViewController: NSViewController, NSCollectionViewDelegate {
    var onActivate: ((OMTSource) -> Void)?
    var onConnectAddress: (() -> Void)?
    var onEscape: (() -> Void)?
    private let previews: SourcePreviewCoordinator
    private let collection = SourceCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    private let scroll = NSScrollView()
    private let discoveryStatus = NSTextField(wrappingLabelWithString: "Looking for OMT sources…")
    private let previewStatus = NSTextField(labelWithString: "Previews are silent")
    private var dataSource: NSCollectionViewDiffableDataSource<Int, String>!
    private var sources: [OMTSource] = []
    private var sourceByID: [String: OMTSource] = [:]
    private var playingID: String?
    private var currentStatus = "Looking for OMT sources…"
    private var refreshScheduled = false
    private var stopped = false
    private var windowObservers: [NSObjectProtocol] = []
    private var scrollObserver: NSObjectProtocol?
    private var clipFrameObserver: NSObjectProtocol?
    private var viewportSize = NSSize.zero
    private weak var observedWindow: NSWindow?
    private static let itemIdentifier = NSUserInterfaceItemIdentifier("SourceThumbnail")

    init(maximumPreviewCount: Int = 12,
         previewFactory: @escaping SourcePreviewCoordinator.Factory = { SourceThumbnailPreview(source: $0) }) {
        previews = SourcePreviewCoordinator(maximumPreviewCount: maximumPreviewCount, factory: previewFactory)
        super.init(nibName: nil, bundle: nil)
        previews.onChange = { [weak self] in self?.renderVisibleItems() }
    }

    var collectionView: SourceCollectionView { loadViewIfNeeded(); return collection }
    var activationSource: OMTSource? {
        if isViewLoaded, let path = collection.selectionIndexPaths.sorted().first,
           let id = dataSource.itemIdentifier(for: path), let source = sourceByID[id] { return source }
        return playingID.flatMap { sourceByID[$0] } ?? sources.first
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    override func loadView() {
        let root = SourceBrowserRootView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        root.onLayout = { [weak self] in self?.updateGridLayout() }
        root.onWindowChanged = { [weak self] in self?.observeWindow() }
        root.onVisibilityChanged = { [weak self] in self?.scheduleVisibleRefresh() }
        view = root
        let heading = NSTextField(labelWithString: "Sources")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        let instruction = NSTextField(labelWithString: "Click a preview to play fullscreen")
        instruction.textColor = .secondaryLabelColor
        instruction.font = .systemFont(ofSize: 12)
        let manual = NSButton(title: "Connect to Address…", target: self, action: #selector(connectAddress))
        manual.bezelStyle = .rounded
        manual.setAccessibilityHelp("Add an OMT sender using its host and TCP port.")
        let header = NSStackView(views: [heading, NSView(), manual])
        header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 16
        heading.setContentHuggingPriority(.required, for: .horizontal)
        manual.setContentHuggingPriority(.required, for: .horizontal)
        layout.minimumInteritemSpacing = 16; layout.minimumLineSpacing = 16
        layout.sectionInset = NSEdgeInsets(top: 4, left: 20, bottom: 20, right: 20)
        layout.itemSize = NSSize(width: 260, height: 260 * 9 / 16 + 66)
        collection.collectionViewLayout = layout
        collection.autoresizingMask = [.width, .height]
        collection.backgroundColors = [.clear]
        collection.isSelectable = true; collection.allowsMultipleSelection = false
        collection.delegate = self
        collection.register(SourceThumbnailItem.self, forItemWithIdentifier: Self.itemIdentifier)
        collection.setAccessibilityLabel("Live OMT sources")
        collection.setAccessibilityHelp("Use arrow keys to browse. Press Return or Space, or click a source, to play fullscreen.")
        collection.onActivate = { [weak self] indexPath in self?.activate(at: indexPath) }
        collection.onEscape = { [weak self] in self?.onEscape?() }
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.documentView = collection
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated {
            self?.updateGridLayout(); self?.scheduleVisibleRefresh()
        } }
        clipFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated {
            self?.updateGridLayout(); self?.scheduleVisibleRefresh()
        } }
        discoveryStatus.font = .systemFont(ofSize: 11); discoveryStatus.textColor = .secondaryLabelColor
        discoveryStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewStatus.font = .systemFont(ofSize: 11); previewStatus.textColor = .secondaryLabelColor
        previewStatus.setContentHuggingPriority(.required, for: .horizontal)
        let footer = NSStackView(views: [discoveryStatus, NSView(), previewStatus])
        footer.orientation = .horizontal; footer.spacing = 12; footer.alignment = .centerY
        for child in [header, instruction, scroll, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            instruction.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            instruction.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: instruction.bottomAnchor, constant: 16),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
        ])
        dataSource = NSCollectionViewDiffableDataSource<Int, String>(collectionView: collection) { [weak self] view, path, id in
            guard let self, let source = self.sourceByID[id] else { return nil }
            let item = view.makeItem(withIdentifier: Self.itemIdentifier, for: path) as! SourceThumbnailItem
            item.sourceID = id
            item.card.onActivate = { [weak self] in self?.activate(sourceID: id) }
            self.render(item, source: source)
            return item
        }
        applySnapshot(previous: [])
        renderStatus()
    }

    func update(sources updated: [OMTSource], status: String, selectedSource: OMTSource?) {
        guard !stopped else { return }
        var seen = Set<String>()
        let unique = updated.filter { seen.insert($0.id).inserted }
        let old = sources
        sources = unique
        sourceByID = Dictionary(unique.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        playingID = selectedSource?.id
        currentStatus = status
        guard isViewLoaded else { return }
        if old != unique { applySnapshot(previous: old) }
        renderVisibleItems()
        scheduleVisibleRefresh()
    }

    /// A fullscreen return can deliberately restore the program tile's focus;
    /// ordinary discovery/program-state updates never move keyboard selection.
    func focusSelectedSource() {
        loadViewIfNeeded()
        let target = playingID.flatMap { dataSource.indexPath(for: $0) } ??
            collection.selectionIndexPaths.sorted().first ??
            (sources.isEmpty ? nil : IndexPath(item: 0, section: 0))
        if let target {
            collection.selectionIndexPaths = [target]
            collection.scrollToItems(at: [target], scrollPosition: .nearestVerticalEdge)
        }
        view.window?.makeFirstResponder(collection)
    }

    func stop(completion: @escaping @MainActor @Sendable () -> Void) {
        stopped = true
        previews.stop(completion: completion)
    }

    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) { scheduleVisibleRefresh() }
    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) { scheduleVisibleRefresh() }

    private func applySnapshot(previous: [OMTSource]) {
        let selectedIDs = Set(collection.selectionIndexPaths.compactMap { path in
            previous.indices.contains(path.item) ? previous[path.item].id : nil
        })
        let oldByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0]); snapshot.appendItems(sources.map(\.id), toSection: 0)
        // A name/address correction updates its item without disturbing other
        // identities or reconnecting their independently retained previews.
        let changed = sources.filter { oldByID[$0.id] != nil && oldByID[$0.id] != $0 }.map(\.id)
        snapshot.reloadItems(changed)
        dataSource.apply(snapshot, animatingDifferences: false)
        let selectedPaths = Set(selectedIDs.compactMap { dataSource.indexPath(for: $0) })
        collection.selectionIndexPaths = selectedPaths
        scheduleVisibleRefresh()
    }

    private func updateGridLayout() {
        let viewport = scroll.contentView.bounds.size
        let width = viewport.width
        guard width > 0 else { return }
        let available = max(1, width - layout.sectionInset.left - layout.sectionInset.right)
        let columns = max(1, Int((available + 16) / (240 + 16)))
        let itemWidth = floor((available - CGFloat(columns - 1) * 16) / CGFloat(columns))
        let size = NSSize(width: max(160, itemWidth), height: max(160, itemWidth) * 9 / 16 + 66)
        guard viewportSize != viewport || layout.itemSize != size else { return }
        viewportSize = viewport
        if layout.itemSize != size { layout.itemSize = size; layout.invalidateLayout() }
        scheduleVisibleRefresh()
    }

    private func scheduleVisibleRefresh() {
        guard !stopped, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshVisiblePreviews()
        }
    }

    private func refreshVisiblePreviews() {
        guard !stopped, isViewLoaded else { return }
        guard let window = view.window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible), !view.isHiddenOrHasHiddenAncestor else {
            previews.setVisibleSources([])
            return
        }
        let visible = collection.indexPathsForVisibleItems().sorted().compactMap { path -> OMTSource? in
            guard let id = dataSource.itemIdentifier(for: path) else { return nil }
            return sourceByID[id]
        }
        previews.setVisibleSources(visible)
        renderVisibleItems()
    }

    private func observeWindow() {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        observedWindow = view.window
        if let window = observedWindow {
            // Miniaturization is a separate lifecycle event. Do not depend on
            // WindowServer delivering an occlusion update in the same turn.
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleVisibleRefresh() } })
            }
        }
        scheduleVisibleRefresh()
    }

    private func renderVisibleItems() {
        guard isViewLoaded else { return }
        for case let item as SourceThumbnailItem in collection.visibleItems() {
            guard let id = item.sourceID, let source = sourceByID[id] else { continue }
            render(item, source: source)
        }
        renderStatus()
    }

    private func render(_ item: SourceThumbnailItem, source: OMTSource) {
        let preview = previews.preview(for: source.id)
        let state: String
        if let preview { state = preview.statusText }
        else if previews.pausedVisibleCount > 0 { state = "Preview paused · \(previews.maximumPreviewCount)-preview limit" }
        else { state = "Starting preview…" }
        item.card.configure(source: source, status: state, format: preview?.formatText ?? "",
                            isPlaying: source.id == playingID, preview: preview?.view)
        let menu = NSMenu(title: source.name)
        menu.autoenablesItems = false
        let retry = NSMenuItem(title: "Retry Preview", action: #selector(retryPreview(_:)), keyEquivalent: "")
        retry.target = self; retry.representedObject = source.id
        retry.isEnabled = previews.canRetry(sourceID: source.id)
        menu.addItem(retry)
        item.card.menu = menu
    }

    private func renderStatus() {
        if discoveryStatus.stringValue != currentStatus { discoveryStatus.stringValue = currentStatus }
        discoveryStatus.toolTip = currentStatus
        let paused = previews.pausedVisibleCount
        let previewText = paused > 0 ? "\(previews.activeIDs.count) live · \(paused) paused · Silent previews" : "Silent live previews"
        if previewStatus.stringValue != previewText { previewStatus.stringValue = previewText }
        previewStatus.toolTip = "Up to \(previews.maximumPreviewCount) visible sources preview simultaneously. Fullscreen uses the original stream format."
    }

    private func activate(at indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        activate(sourceID: id)
    }
    private func activate(sourceID: String) {
        guard !stopped, let source = sourceByID[sourceID] else { return }
        if let path = dataSource.indexPath(for: sourceID) { collection.selectionIndexPaths = [path] }
        view.window?.makeFirstResponder(collection)
        onActivate?(source)
    }
    @objc private func retryPreview(_ item: NSMenuItem) {
        guard !stopped, let id = item.representedObject as? String else { return }
        previews.retry(sourceID: id)
        renderVisibleItems()
    }
    @objc private func connectAddress() { onConnectAddress?() }

    deinit {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let clipFrameObserver { NotificationCenter.default.removeObserver(clipFrameObserver) }
    }
}

@MainActor
private final class SourceBrowserRootView: NSView {
    var onLayout: (() -> Void)?
    var onWindowChanged: (() -> Void)?
    var onVisibilityChanged: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindowChanged?() }
    override func viewDidHide() { super.viewDidHide(); onVisibilityChanged?() }
    override func viewDidUnhide() { super.viewDidUnhide(); onVisibilityChanged?() }
}

@MainActor
final class SourceCollectionView: NSCollectionView {
    var onActivate: ((IndexPath) -> Void)?
    var onEscape: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    // Card mouse events retain AppKit's collection gesture/selection machinery.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        if event.keyCode == 36 || event.keyCode == 76 || event.charactersIgnoringModifiers == " " {
            if selectionIndexPaths.isEmpty, numberOfSections > 0, numberOfItems(inSection: 0) > 0 {
                selectItems(at: [IndexPath(item: 0, section: 0)], scrollPosition: [])
            }
            if let selected = selectionIndexPaths.sorted().first { onActivate?(selected) }
            return
        }
        super.keyDown(with: event)
    }
}
