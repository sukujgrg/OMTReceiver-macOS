import AppKit
import XCTest
@testable import OMTReceiver

@MainActor
final class PreviewRetryTests: XCTestCase {
    func testOnlyActiveFailedPreviewCanRetryWithoutBypassingRetirementBudget() {
        let first = OMTSource(id: "retry:first", name: "First", address: "first")
        let second = OMTSource(id: "retry:second", name: "Second", address: "second")
        var made: [RetryPreviewFixture] = []
        let coordinator = SourcePreviewCoordinator(maximumPreviewCount: 1) { source in
            let preview = RetryPreviewFixture(source: source)
            made.append(preview)
            return preview
        }
        coordinator.setVisibleSources([first])
        XCTAssertTrue(coordinator.canRetry(sourceID: first.id))
        coordinator.retry(sourceID: first.id)
        XCTAssertEqual(made[0].retries, 1)
        XCTAssertFalse(coordinator.canRetry(sourceID: first.id))
        coordinator.retry(sourceID: first.id)
        XCTAssertEqual(made[0].retries, 1, "A running preview must not reconnect on repeated Retry commands")

        made[0].failed = true
        coordinator.setVisibleSources([second])
        XCTAssertFalse(coordinator.canRetry(sourceID: first.id))
        coordinator.retry(sourceID: first.id)
        XCTAssertEqual(made[0].retries, 1, "A removed or retiring preview must never restart")
        XCTAssertEqual(made.count, 1, "Retirement still consumes the preview budget")
        made[0].finishStop()
        XCTAssertEqual(made.count, 2)
        XCTAssertTrue(coordinator.canRetry(sourceID: second.id))
        var stopped = false
        coordinator.stop { stopped = true }
        coordinator.retry(sourceID: second.id)
        XCTAssertEqual(made[1].retries, 0)
        made[1].finishStop()
        XCTAssertTrue(stopped)
    }

    func testTerminalReceiverFailureAllowsOneDeliberateRetryAndNeverRevivesAfterStop() async throws {
        XCTAssertNil(OMTSDKRuntime.shared.load())
        // The bridge rejects an empty address before creating an SDK receiver.
        // This exercises the actual async session terminal-state delivery.
        let source = OMTSource(id: "retry:invalid", name: "Invalid", address: "")
        let preview = SourceThumbnailPreview(source: source)
        preview.start()
        await waitForFailure(preview)
        XCTAssertTrue(preview.canRetry)
        preview.retry()
        XCTAssertFalse(preview.canRetry, "Retry starts a fresh epoch rather than recursively retrying failures")
        await waitForFailure(preview)
        XCTAssertTrue(preview.canRetry)
        await withCheckedContinuation { continuation in preview.stop { continuation.resume() } }
        XCTAssertFalse(preview.canRetry)
        preview.retry()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(preview.canRetry, "A stopped tile cannot be revived by a delayed menu command")
    }

    private func waitForFailure(_ preview: SourceThumbnailPreview) async {
        let deadline = Date().addingTimeInterval(2)
        while !preview.canRetry, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@MainActor
private final class RetryPreviewFixture: SourceThumbnailPreviewing {
    let source: OMTSource
    let view = NSView()
    var statusText = "Preview unavailable"
    var formatText = ""
    var onChange: (() -> Void)?
    var failed = true
    private var stopped = false
    private var completion: (@MainActor @Sendable () -> Void)?
    private(set) var retries = 0
    var canRetry: Bool { failed && !stopped }
    init(source: OMTSource) { self.source = source }
    func start() {}
    func retry() { retries += 1; failed = false }
    func stop(completion: @escaping @MainActor @Sendable () -> Void) { stopped = true; self.completion = completion }
    func finishStop() { completion?(); completion = nil }
}
