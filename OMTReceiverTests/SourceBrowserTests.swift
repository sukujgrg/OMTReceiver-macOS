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
        let sources = [source("a"), source("b")]
        browser.update(sources: sources, status: "2 sources", selectedSource: sources[0])
        let collection = browser.collectionView
        collection.selectItems(at: [IndexPath(item: 1, section: 0)], scrollPosition: [])
        let selection = collection.selectionIndexPaths
        browser.update(sources: sources, status: "2 sources", selectedSource: sources[0])
        XCTAssertEqual(collection.selectionIndexPaths, selection)
        XCTAssertEqual(browser.activationSource, sources[1])
        XCTAssertEqual(created, 0, "Loading an unattached browser must not open network connections")
        var stopped = false
        browser.stop { stopped = true }
        XCTAssertTrue(stopped)
    }

    func testOneClickActivatesAndTheSecondClickOfADoubleClickDoesNotToggle() throws {
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
        let first = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        card.mouseDown(with: first)
        XCTAssertEqual(activated, [source("a")])
        let second = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: 1.1, windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, clickCount: 2, pressure: 1))
        card.mouseDown(with: second)
        XCTAssertEqual(activated.count, 1)
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

    func testCardReplacementDetachesOldSurfaceAndAccessibilityPressActivatesOnce() {
        let card = SourceThumbnailCard()
        let old = NSView(), replacement = NSView()
        card.configure(source: source("a"), status: "Live", format: "", isPlaying: false, preview: old)
        XCTAssertNotNil(old.superview)
        card.configure(source: source("a"), status: "Live", format: "", isPlaying: true, preview: replacement)
        XCTAssertNil(old.superview)
        XCTAssertNotNil(replacement.superview)
        var presses = 0
        card.onActivate = { presses += 1 }
        XCTAssertTrue(card.accessibilityPerformPress())
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
        return (browser, window)
    }
    private func key(_ characters: String, code: UInt16, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 2, windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
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
