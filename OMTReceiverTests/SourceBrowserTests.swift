import AppKit
import XCTest
@testable import OMTReceiver

@MainActor
final class SourceBrowserTests: XCTestCase {
    func testPreviewBudgetIncludesRetiringWorkersAndKeepsUnchangedPreview() {
        let a = source("a"), b = source("b"), c = source("c")
        var made: [PreviewFixture] = []
        let pool = SourcePreviewCoordinator(maximumPreviewCount: 2) { source in
            let preview = PreviewFixture(source: source); made.append(preview); return preview
        }
        pool.setVisibleSources([a, b])
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(pool.activeIDs, [a.id, b.id])
        pool.setVisibleSources([a, b])
        XCTAssertEqual(made.count, 2, "An unchanged viewport must not reconnect preview streams")
        let kept = pool.preview(for: b.id)
        pool.setVisibleSources([b, c])
        XCTAssertEqual(pool.activeIDs, [b.id])
        XCTAssertEqual(pool.retiringCount, 1)
        XCTAssertNil(pool.preview(for: c.id), "The retiring SDK receiver still consumes one budget slot")
        XCTAssertTrue(pool.preview(for: b.id) === kept)
        made[0].finishStop()
        XCTAssertEqual(made.count, 3)
        XCTAssertEqual(pool.activeIDs, [b.id, c.id])
        var completions = 0
        pool.stop { completions += 1 }
        pool.stop { completions += 1 }
        XCTAssertEqual(completions, 0)
        made[1].finishStop()
        XCTAssertEqual(completions, 0)
        made[2].finishStop()
        XCTAssertEqual(completions, 2)
        XCTAssertTrue(pool.activeIDs.isEmpty)
        XCTAssertEqual(pool.retiringCount, 0)
    }

    func testAddressReplacementAndStopDoNotReviveRemovedPreview() {
        let original = source("same")
        let replacement = OMTSource(id: original.id, name: "Replacement", address: "omt://127.0.0.1:29999")
        var made: [PreviewFixture] = []
        let pool = SourcePreviewCoordinator(maximumPreviewCount: 1) { source in
            let preview = PreviewFixture(source: source); made.append(preview); return preview
        }
        pool.setVisibleSources([original])
        pool.setVisibleSources([replacement])
        XCTAssertEqual(made.count, 1)
        XCTAssertNil(made[0].onChange, "A retiring source cannot publish stale tile state")
        var stopped = false
        pool.stop { stopped = true }
        made[0].finishStop()
        XCTAssertTrue(stopped)
        XCTAssertEqual(made.count, 1, "The canceled replacement must never create a new SDK receiver")
        pool.setVisibleSources([replacement])
        XCTAssertEqual(made.count, 1)
    }

    func testHiddenBrowserStartsNoPreviewsAndProgramChangesPreserveBrowseSelection() {
        var created = 0
        let browser = SourceBrowserViewController { source in
            created += 1; return PreviewFixture(source: source, stopImmediately: true)
        }
        let sources = [source("a"), source("b"), source("c")]
        browser.update(sources: sources, status: "3 sources", selectedSource: sources[0])
        let collection = browser.collectionView
        collection.selectItems(at: [IndexPath(item: 1, section: 0)], scrollPosition: [])
        let selection = collection.selectionIndexPaths
        browser.update(sources: sources, status: "3 sources", selectedSource: sources[2])
        XCTAssertEqual(collection.selectionIndexPaths, selection)
        XCTAssertEqual(browser.activationSource, sources[1])
        browser.update(sources: [sources[2], sources[0], sources[1]], status: "3 sources", selectedSource: nil)
        XCTAssertEqual(collection.selectionIndexPaths, [IndexPath(item: 2, section: 0)], "Discovery reordering retains the browsed identity")
        XCTAssertEqual(browser.activationSource, sources[1])
        XCTAssertEqual(created, 0, "Loading an unattached browser must not open network connections")
        var stopped = false
        browser.stop { stopped = true }
        XCTAssertTrue(stopped)
    }

    func testWindowVisibilityTransitionsRetireBeforeRestartingPreviews() async throws {
        var made: [PreviewFixture] = []
        let browser = SourceBrowserViewController(maximumPreviewCount: 2) { source in
            let preview = PreviewFixture(source: source); made.append(preview); return preview
        }
        browser.update(sources: [source("a"), source("b")], status: "2 sources", selectedSource: nil)
        let window = PreviewVisibilityWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                             styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        window.contentView?.layoutSubtreeIfNeeded()
        browser.collectionView.layoutSubtreeIfNeeded()
        window.orderFront(nil)
        defer {
            browser.stop {}
            made.forEach { $0.finishStop() }
            window.close()
        }
        await flushBrowserUpdates()
        XCTAssertEqual(made.count, 2)
        guard made.count == 2 else { return }
        XCTAssertTrue(made.allSatisfy { $0.starts == 1 })

        // An occluded window retires its receivers. Becoming visible again
        // must wait for those workers instead of exceeding the resource budget.
        window.reportedOcclusion = []
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        await flushBrowserUpdates()
        XCTAssertTrue(made.allSatisfy { $0.stops == 1 })
        window.reportedOcclusion = .visible
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        await flushBrowserUpdates()
        XCTAssertEqual(made.count, 2)
        made[0].finishStop(); made[1].finishStop()
        XCTAssertEqual(made.count, 4)
        guard made.count == 4 else { return }

        // Exercise the distinct miniaturization notification without relying
        // on an accompanying occlusion update from the hosted WindowServer.
        window.reportedMiniaturized = true
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
        await flushBrowserUpdates()
        XCTAssertEqual(made[2].stops, 1); XCTAssertEqual(made[3].stops, 1)
        made[2].finishStop(); made[3].finishStop()
        window.reportedMiniaturized = false
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        await flushBrowserUpdates()
        XCTAssertEqual(made.count, 6)
        guard made.count == 6 else { return }

        // Hiding the view itself is independent of window occlusion.
        browser.view.isHidden = true
        await flushBrowserUpdates()
        XCTAssertEqual(made[4].stops, 1); XCTAssertEqual(made[5].stops, 1)
        made[4].finishStop(); made[5].finishStop()
        browser.view.isHidden = false
        await flushBrowserUpdates()
        XCTAssertEqual(made.count, 8)
        guard made.count == 8 else { return }

        // Finally use real AppKit window ordering to exercise isVisible.
        window.orderOut(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        await flushBrowserUpdates()
        XCTAssertEqual(made[6].stops, 1); XCTAssertEqual(made[7].stops, 1)
    }

    func testNativeButtonActionUsesHitSourceAndRestoresCollectionSelection() throws {
        let (browser, window) = makeBrowser()
        defer { browser.stop {}; window.close() }
        let collection = browser.collectionView
        var activated: [OMTSource] = []
        browser.onActivate = { activated.append($0) }
        let path = IndexPath(item: 0, section: 0)
        let attributes = try XCTUnwrap(collection.collectionViewLayout?.layoutAttributesForItem(at: path))
        XCTAssertGreaterThan(attributes.frame.width, 160)
        let local = NSPoint(x: attributes.frame.midX, y: attributes.frame.midY)
        XCTAssertEqual(collection.indexPathForItem(at: local), path)
        let card = try XCTUnwrap(collection.item(at: path)?.view as? SourceThumbnailCard)
        let point = collection.convert(local, to: nil)
        let hit = window.contentView?.hitTest(window.contentView?.superview?.convert(point, from: nil) ?? point)
        XCTAssertTrue(hit === card, "The displayed picture must hit its owning native source button")
        card.performClick(nil)
        XCTAssertEqual(activated, [source("a")])
        XCTAssertEqual(collection.selectionIndexPaths, [path])
        XCTAssertTrue(window.firstResponder === collection)
        let secondPath = IndexPath(item: 1, section: 0)
        let second = try XCTUnwrap(collection.item(at: secondPath)?.view as? SourceThumbnailCard)
        second.performClick(nil)
        XCTAssertEqual(activated, [source("a"), source("b")])
        XCTAssertEqual(collection.selectionIndexPaths, [secondPath])
        XCTAssertEqual(browser.activationSource, source("b"))
    }

    func testSourceButtonUsesNativeReleaseAndSingleClickPolicies() {
        let card = SourceThumbnailCard()
        XCTAssertTrue(card.ignoresMultiClick)
        XCTAssertFalse(card.isContinuous)
        let originalMask = card.sendAction(on: .leftMouseUp)
        XCTAssertEqual(originalMask, Int(NSEvent.EventTypeMask.leftMouseUp.rawValue))
        // AppKit owns pointer tracking. Drag-out cancellation and double-click
        // behavior are qualified in the standalone app; this hosted XCTest
        // process cannot obtain WindowServer foreground activation.
    }

    func testKeyboardSelectionIsPrivateUntilSpaceOrReturnAndEscapeIsForwarded() throws {
        let (browser, window) = makeBrowser()
        defer { browser.stop {}; window.close() }
        let collection = browser.collectionView
        var activated: [OMTSource] = []
        var escaped = 0
        browser.onActivate = { activated.append($0) }
        browser.onEscape = { escaped += 1 }
        collection.selectItems(at: [IndexPath(item: 1, section: 0)], scrollPosition: [])
        XCTAssertTrue(activated.isEmpty)
        collection.keyDown(with: try key(" ", code: 49, window: window))
        XCTAssertEqual(activated, [source("b")])
        collection.keyDown(with: try key("\r", code: 36, window: window))
        XCTAssertEqual(activated, [source("b"), source("b")])
        collection.keyDown(with: try key("\u{1b}", code: 53, window: window))
        XCTAssertEqual(escaped, 1)
    }

    func testWindowResponderRoutesArrowNavigationAndActivationToTheSameSource() throws {
        let (browser, window) = makeBrowser()
        defer { browser.stop {}; window.close() }
        let collection = browser.collectionView
        let first = IndexPath(item: 0, section: 0), second = IndexPath(item: 1, section: 0)
        collection.selectionIndexPaths = [first]
        XCTAssertTrue(window.makeFirstResponder(collection))
        var activated: [OMTSource] = []
        browser.onActivate = { activated.append($0) }

        window.sendEvent(try key("\u{f703}", code: 124, window: window))
        XCTAssertEqual(collection.selectionIndexPaths, [second])
        XCTAssertTrue(activated.isEmpty, "Arrow navigation must not switch the live output")
        let firstCard = try XCTUnwrap(collection.item(at: first)?.view as? SourceThumbnailCard)
        let secondCard = try XCTUnwrap(collection.item(at: second)?.view as? SourceThumbnailCard)
        XCTAssertFalse(firstCard.isAccessibilitySelected())
        XCTAssertTrue(secondCard.isAccessibilitySelected())

        window.sendEvent(try key("\r", code: 36, window: window))
        XCTAssertEqual(activated, [source("b")])
        XCTAssertTrue(window.firstResponder === collection)
    }

    func testCardReplacementDetachesOldSurfaceAndAccessibilityPressActivatesOnce() {
        let card = SourceThumbnailCard()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = card
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        defer { window.close() }
        let old = NSView(), replacement = NSView()
        card.configure(source: source("a"), status: "Live", format: "", isPlaying: false, preview: old)
        XCTAssertNotNil(old.superview)
        card.configure(source: source("a"), status: "Live", format: "", isPlaying: true, preview: replacement)
        XCTAssertNil(old.superview)
        XCTAssertNotNil(replacement.superview)
        var presses = 0
        card.onActivate = { presses += 1 }
        XCTAssertEqual(card.accessibilityRole(), .button)
        XCTAssertEqual(card.accessibilityLabel(), "Source a")
        XCTAssertEqual(card.accessibilityValue() as? String, "Playing fullscreen. Live")
        XCTAssertFalse(card.isAccessibilitySelected(), "Playing does not implicitly change browse selection")
        card.isSelected = true
        XCTAssertTrue(card.isAccessibilitySelected())
        // NSButton dispatches the native press but can return false in the
        // inactive XCTest host. The observable contract is one activation.
        _ = card.accessibilityPerformPress()
        XCTAssertEqual(presses, 1)
        card.detachPreview()
        XCTAssertNil(replacement.superview)
    }

    private func source(_ id: String) -> OMTSource {
        OMTSource(id: id, name: "Source \(id)", address: "omt://\(id).local:6400")
    }
    private func makeBrowser() -> (SourceBrowserViewController, NSWindow) {
        let browser = SourceBrowserViewController(previewFactory: { PreviewFixture(source: $0, stopImmediately: true) })
        browser.update(sources: [source("a"), source("b")], status: "2 sources", selectedSource: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        window.setContentSize(NSSize(width: 900, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        browser.collectionView.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        return (browser, window)
    }
    private func key(_ characters: String, code: UInt16, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 2, windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func flushBrowserUpdates() async {
        // The browser coalesces native notifications onto the next main turn.
        // Two turns also drain work scheduled by layout during reconciliation.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { DispatchQueue.main.async { continuation.resume() } }
        }
    }

}

/// The hosted test process cannot own foreground activation. Keep real window
/// attachment/ordering and notifications, while supplying the two WindowServer
/// observations needed to test lifecycle handling deterministically.
@MainActor
private final class PreviewVisibilityWindow: NSWindow {
    var reportedOcclusion: NSWindow.OcclusionState = .visible
    var reportedMiniaturized = false
    override var occlusionState: NSWindow.OcclusionState { reportedOcclusion }
    override var isMiniaturized: Bool { reportedMiniaturized }
}

@MainActor
private final class PreviewFixture: SourceThumbnailPreviewing {
    let source: OMTSource
    let view = NSView()
    var statusText = "Live"
    var formatText = "320 × 180p · 15 fps"
    var onChange: (() -> Void)?
    var starts = 0
    var stops = 0
    private let stopImmediately: Bool
    private var completions: [@MainActor @Sendable () -> Void] = []
    init(source: OMTSource, stopImmediately: Bool = false) {
        self.source = source; self.stopImmediately = stopImmediately
    }
    func start() { starts += 1 }
    func stop(completion: @escaping @MainActor @Sendable () -> Void) {
        stops += 1
        if stopImmediately { completion() } else { completions.append(completion) }
    }
    func finishStop() {
        let pending = completions; completions.removeAll()
        pending.forEach { $0() }
    }
}
