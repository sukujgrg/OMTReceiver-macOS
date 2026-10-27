import AppKit
import XCTest
@testable import OMTReceiver

@MainActor
final class PreviewRetryTests: XCTestCase {
    func testAutomaticRetryBackoffIsBoundedAcrossUnsuccessfulConnections() {
        var backoff = ReceiverReconnectBackoff()
        for (attempt, delay) in [1.0, 2, 4, 8, 16, 30, 30].enumerated() {
            let stalledAt = Double(attempt) * 100
            XCTAssertFalse(backoff.shouldReconnect(state: .stalled, at: stalledAt))
            XCTAssertFalse(backoff.shouldReconnect(state: .stalled, at: stalledAt + delay - 0.001))
            XCTAssertTrue(backoff.shouldReconnect(state: .stalled, at: stalledAt + delay),
                          "A continuously unavailable sender must back off without exceeding the 30-second delay")
            XCTAssertFalse(backoff.shouldReconnect(state: .waiting, at: stalledAt + delay + 0.001),
                           "Starting the next connection must not reset consecutive-failure backoff")
        }
    }

    func testLiveMediaCancelsPendingRetryAndResetsBackoff() {
        var backoff = ReceiverReconnectBackoff()
        XCTAssertFalse(backoff.shouldReconnect(state: .stalled, at: 0))
        XCTAssertTrue(backoff.shouldReconnect(state: .stalled, at: 1))
        XCTAssertFalse(backoff.shouldReconnect(state: .waiting, at: 1.1))
        XCTAssertFalse(backoff.shouldReconnect(state: .stalled, at: 2))
        XCTAssertFalse(backoff.shouldReconnect(state: .live, at: 3))
        for time in [4.0, 10, 30, 100] {
            XCTAssertFalse(backoff.shouldReconnect(state: .live, at: time),
                           "Healthy frame arrivals must never cause periodic receiver resets")
        }
        XCTAssertFalse(backoff.shouldReconnect(state: .stalled, at: 101))
        XCTAssertFalse(backoff.shouldReconnect(state: .stalled, at: 101.999))
        XCTAssertTrue(backoff.shouldReconnect(state: .stalled, at: 102),
                      "A new loss after successful reception starts with the initial delay")
    }

    func testWaitingAndUnsupportedMediaCancelObsoleteRetryDeadlines() {
        var backoff = ReceiverReconnectBackoff()
        XCTAssertFalse(backoff.shouldReconnect(state: .stalled, at: 0))
        XCTAssertFalse(backoff.shouldReconnect(state: .waiting, at: 0.5))
        XCTAssertFalse(backoff.shouldReconnect(state: .waiting, at: 2))
        XCTAssertFalse(backoff.shouldReconnect(state: .unsupported, at: 3))
        XCTAssertFalse(backoff.shouldReconnect(state: .stalled, at: 4))
        XCTAssertTrue(backoff.shouldReconnect(state: .stalled, at: 5))

        XCTAssertFalse(backoff.shouldReconnect(state: .waiting, at: 5.1))
        XCTAssertFalse(backoff.shouldReconnect(state: .unsupported, at: 6))
        XCTAssertFalse(backoff.shouldReconnect(state: .stalled, at: 10))
        XCTAssertFalse(backoff.shouldReconnect(state: .stalled, at: 11))
        XCTAssertTrue(backoff.shouldReconnect(state: .stalled, at: 12),
                      "A connecting or unsupported source must not silently clear failure history")
    }

    func testExplicitResetDiscardsThePendingAutomaticRetry() {
        var backoff = ReceiverReconnectBackoff()
        XCTAssertFalse(backoff.shouldReconnect(state: .stalled, at: 0))
        XCTAssertTrue(backoff.shouldReconnect(state: .stalled, at: 1))
        XCTAssertFalse(backoff.shouldReconnect(state: .waiting, at: 1.1))
        XCTAssertFalse(backoff.shouldReconnect(state: .stalled, at: 2))
        backoff.reset()
        XCTAssertFalse(backoff.shouldReconnect(state: .waiting, at: 100),
                       "A stopped or manually restarted preview must not retain an old retry deadline")
        XCTAssertFalse(backoff.shouldReconnect(state: .stalled, at: 101))
        XCTAssertTrue(backoff.shouldReconnect(state: .stalled, at: 102))
    }

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

    func testRetryDoesNotReconnectIfDisconnectedNotificationStopsPreview() async throws {
        XCTAssertNil(OMTSDKRuntime.shared.load())
        let source = OMTSource(id: "retry:retired-during-restart", name: "Invalid", address: "")
        let preview = SourceThumbnailPreview(source: source)
        preview.start()
        await waitForFailure(preview)
        XCTAssertTrue(preview.canRetry)

        let stopped = expectation(description: "Preview retires during the retry's disconnect notification")
        var requestedStop = false
        preview.onChange = { [weak preview] in
            guard let preview, !requestedStop, preview.statusText == "Disconnected" else { return }
            requestedStop = true
            preview.stop { stopped.fulfill() }
        }
        defer { preview.onChange = nil }

        preview.retry()
        XCTAssertTrue(requestedStop, "The observer must retire the preview synchronously during restart")
        XCTAssertEqual(preview.statusText, "Disconnected", "Restart must not recreate a receiver after its observer stops the tile")
        await fulfillment(of: [stopped], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(preview.statusText, "Disconnected", "Queued receiver updates must not revive a retired preview")
        XCTAssertFalse(preview.canRetry)
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
