import XCTest
import Metal
import QuartzCore
@testable import OMTReceiver

@MainActor
final class VideoHealthTests: XCTestCase {
    func testBufferFailureRetainsLastPictureAndSuccessfulAllocationRestoresHealth() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var failAllocation = false
        var allocations = 0
        let view = VideoView(clock: PlaybackClock(latency: 0), device: device) { device, bytes, count in
            allocations += 1
            return failAllocation ? nil : device.makeBuffer(bytes: bytes, length: count, options: .storageModeShared)
        }
        view.isPaused = true
        XCTAssertNil(view.errorMessage)
        var observed: [String?] = []
        view.onStateChange = { [weak view] in observed.append(view?.errorMessage) }
        view.enqueue(frame(width: 2, timestamp: 1))
        XCTAssertTrue(view.prepareDueFrame(at: CACurrentMediaTime() + 1))
        let lastGoodFormat = try XCTUnwrap(view.displayedFormat)
        XCTAssertTrue(observed.isEmpty)

        failAllocation = true
        view.enqueue(frame(width: 4, timestamp: 2))
        XCTAssertFalse(view.prepareDueFrame(at: CACurrentMediaTime() + 1))
        let failure = try XCTUnwrap(view.errorMessage)
        XCTAssertTrue(failure.contains("GPU memory"))
        XCTAssertEqual(view.displayedFormat, lastGoodFormat)
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed[0], failure)
        XCTAssertFalse(view.prepareDueFrame(at: CACurrentMediaTime() + 1))
        XCTAssertEqual(view.errorMessage, failure, "A draw with no new allocation is not recovery")
        view.enqueue(frame(width: 4, timestamp: 3))
        XCTAssertFalse(view.prepareDueFrame(at: CACurrentMediaTime() + 1))
        XCTAssertEqual(observed.count, 1, "An unchanged current failure does not flood observers")

        failAllocation = false
        view.enqueue(frame(width: 4, timestamp: 4))
        XCTAssertTrue(view.prepareDueFrame(at: CACurrentMediaTime() + 1))
        XCTAssertNil(view.errorMessage)
        XCTAssertNotEqual(view.displayedFormat, lastGoodFormat)
        XCTAssertEqual(observed.count, 2)
        XCTAssertNil(observed[1])
        XCTAssertEqual(allocations, 4)

        failAllocation = true
        view.enqueue(frame(width: 4, timestamp: 5))
        XCTAssertFalse(view.prepareDueFrame(at: CACurrentMediaTime() + 1))
        XCTAssertEqual(observed.count, 3, "A later failure must be reported again after recovery")
        view.clear()
        XCTAssertNil(view.errorMessage)
        XCTAssertNil(view.displayedFormat)
        XCTAssertEqual(observed.count, 4)
        XCTAssertNil(observed[3])
    }

    func testClearStartsNewSourceEpochWithoutAllocatingQueuedOldFrame() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var allocations = 0
        let view = VideoView(clock: PlaybackClock(latency: 0), device: device) { _, _, _ in
            allocations += 1
            return nil
        }
        view.isPaused = true
        view.enqueue(frame(width: 2, timestamp: 1))
        XCTAssertFalse(view.prepareDueFrame(at: CACurrentMediaTime() + 1))
        XCTAssertNotNil(view.errorMessage)
        view.enqueue(frame(width: 4, timestamp: 2))
        view.clear()
        XCTAssertNil(view.errorMessage)
        XCTAssertFalse(view.prepareDueFrame(at: CACurrentMediaTime() + 1))
        XCTAssertNil(view.displayedFormat)
        XCTAssertEqual(allocations, 1, "The retired source's queued frame must not allocate in the new epoch")
    }

    func testReconnectRetainsDisplayedPictureButDiscardsQueuedOldEpoch() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let clock = PlaybackClock(latency: 0)
        var allocations = 0
        let view = VideoView(clock: clock, device: device) { device, bytes, count in
            allocations += 1
            return device.makeBuffer(bytes: bytes, length: count, options: .storageModeShared)
        }
        view.isPaused = true
        view.enqueue(frame(width: 2, timestamp: 10_000_000))
        XCTAssertTrue(view.prepareDueFrame(at: .infinity))
        let displayed = try XCTUnwrap(view.displayedFormat)
        view.enqueue(frame(width: 4, timestamp: 12_000_000))

        view.prepareForReconnect()

        XCTAssertEqual(view.displayedFormat, displayed, "A reconnect must hold the last good picture rather than black the output")
        XCTAssertFalse(view.prepareDueFrame(at: .infinity), "Queued pictures from the retired receiver must be discarded")
        XCTAssertEqual(allocations, 1, "Resetting reception must not allocate or present the queued old picture")
        view.enqueue(frame(width: 6, timestamp: 0))
        XCTAssertTrue(view.prepareDueFrame(at: CACurrentMediaTime() + 0.01))
        XCTAssertNotEqual(view.displayedFormat, displayed)
        XCTAssertTrue(view.displayedFormat?.contains("6 × 2") == true)
        XCTAssertEqual(allocations, 2)
        XCTAssertNil(view.errorMessage)
    }

    func testClearCannotEraseFatalRendererInitializationFailure() {
        let view = VideoView(device: nil)
        view.isPaused = true
        let failure = view.errorMessage
        XCTAssertNotNil(failure)
        var stateChanges = 0
        view.onStateChange = { stateChanges += 1 }
        view.enqueue(frame(width: 2, timestamp: 1))
        view.clear()
        XCTAssertEqual(view.errorMessage, failure)
        XCTAssertFalse(view.prepareDueFrame(at: CACurrentMediaTime() + 1))
        XCTAssertEqual(view.errorMessage, failure)
        XCTAssertEqual(stateChanges, 0)
    }

    private func frame(width: Int, timestamp: Int64) -> VideoFrame {
        VideoFrame(width: width, height: 2, stride: width * 4, codec: 0x41524742,
                   flags: 0, frameRateN: 60, frameRateD: 1, aspectRatio: Double(width) / 2,
                   colorSpace: 709, timestamp: timestamp, receivedAt: CACurrentMediaTime(),
                   data: Data(repeating: 255, count: width * 2 * 4))
    }
}
