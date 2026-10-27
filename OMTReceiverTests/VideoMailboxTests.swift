import Foundation
import QuartzCore
import XCTest
@testable import OMTReceiver

final class VideoMailboxTests: XCTestCase {
    func testNewestDuePictureIsChosenWithoutConsumingFuturePictures() throws {
        let clock = PlaybackClock()
        let mailbox = VideoMailbox(clock: clock)
        let anchor = clock.presentationTime(for: 0)
        for timestamp: Int64 in [0, 1_000_000, 2_000_000] { mailbox.enqueue(frame(timestamp: timestamp)) }
        XCTAssertNil(mailbox.takeDue(at: anchor - 0.001))
        XCTAssertEqual(mailbox.takeDue(at: anchor + 0.15)?.frame.timestamp, 1_000_000)
        XCTAssertNil(mailbox.takeDue(at: anchor + 0.15), "A presented picture must not be returned twice")
        let future = try XCTUnwrap(mailbox.takeDue(at: anchor + 0.2))
        XCTAssertEqual(future.frame.timestamp, 2_000_000)
        XCTAssertEqual(future.presentationTime, anchor + 0.2, accuracy: 0.000001)
        XCTAssertNil(mailbox.takeDue(at: .infinity))
    }

    func testFrameCountLimitRetainsTheNewestEightPictures() {
        let clock = PlaybackClock()
        let mailbox = VideoMailbox(clock: clock)
        let anchor = clock.presentationTime(for: 0)
        for index in 0..<10 { mailbox.enqueue(frame(timestamp: Int64(index) * 200_000)) }
        XCTAssertNil(mailbox.takeDue(at: anchor + 0.02), "The two oldest pictures exceeded the eight-frame budget")
        let retained = (2..<10).compactMap { mailbox.takeDue(at: anchor + Double($0) * 0.02 + 0.000001)?.frame.timestamp }
        XCTAssertEqual(retained, (2..<10).map { Int64($0) * 200_000 })
        XCTAssertNil(mailbox.takeDue(at: .infinity))
    }

    func testByteLimitCanEvictBeforeTheFrameCountLimit() {
        // Reuse one COW backing allocation: eight distinct pictures account for
        // 144 MiB of logical queue ownership without eight physical allocations.
        let payload = Data(count: 2048 * 2304 * 4) // 18 MiB per decoded picture.
        let clock = PlaybackClock()
        let mailbox = VideoMailbox(clock: clock)
        let anchor = clock.presentationTime(for: 0)
        for index in 0..<8 {
            mailbox.enqueue(frame(timestamp: Int64(index) * 200_000, width: 2048, height: 2304, data: payload))
        }
        XCTAssertNil(mailbox.takeDue(at: anchor), "144 MiB must evict the oldest picture even though there are only eight")
        let retained = (1..<8).compactMap { mailbox.takeDue(at: anchor + Double($0) * 0.02 + 0.000001)?.frame.timestamp }
        XCTAssertEqual(retained, (1..<8).map { Int64($0) * 200_000 }, "Seven pictures use 126 MiB, within the byte budget")
        XCTAssertNil(mailbox.takeDue(at: .infinity))
    }

    func testOneSupportedPictureLargerThanTheQueueBudgetStillOccupiesOneSlot() throws {
        let payload = Data(count: 8192 * 4352 * 4) // 136 MiB; within the supported 256 MiB picture envelope.
        let clock = PlaybackClock()
        let mailbox = VideoMailbox(clock: clock)
        let anchor = clock.presentationTime(for: 0)
        mailbox.enqueue(frame(timestamp: 0, width: 8192, height: 4352, data: payload))
        let admitted = try XCTUnwrap(mailbox.takeDue(at: anchor))
        XCTAssertEqual(admitted.frame.data.count, payload.count)
        XCTAssertNil(mailbox.takeDue(at: .infinity))
        mailbox.enqueue(frame(timestamp: 200_000, width: 8192, height: 4352, data: payload))
        mailbox.enqueue(frame(timestamp: 400_000))
        XCTAssertNil(mailbox.takeDue(at: anchor + 0.02), "A following picture evicts the oversized one rather than retaining both")
        XCTAssertEqual(mailbox.takeDue(at: anchor + 0.04 + 0.000001)?.frame.timestamp, 400_000)
    }

    func testImmediatePreviewReplacesPlaybackBacklogAndKeepsOnlyNewestPicture() throws {
        let clock = PlaybackClock(latency: 0.5)
        let mailbox = VideoMailbox(clock: clock)
        mailbox.enqueue(frame(timestamp: 0))
        mailbox.useImmediatePreview()
        XCTAssertNil(mailbox.takeDue(at: .infinity), "Preview mode drops the previous playout backlog")
        mailbox.enqueue(frame(timestamp: 1))
        let before = CACurrentMediaTime()
        mailbox.enqueue(frame(timestamp: 2))
        let after = CACurrentMediaTime()
        XCTAssertNil(mailbox.takeDue(at: before - 0.001))
        let preview = try XCTUnwrap(mailbox.takeDue(at: after))
        XCTAssertEqual(preview.frame.timestamp, 2)
        XCTAssertGreaterThanOrEqual(preview.presentationTime, before)
        XCTAssertLessThanOrEqual(preview.presentationTime, after)
        XCTAssertNil(mailbox.takeDue(at: .infinity))
    }

    func testOutOfOrderAndRestartTimestampsReplaceTheOldEpoch() throws {
        let clock = PlaybackClock()
        let mailbox = VideoMailbox(clock: clock)
        let anchor = clock.presentationTime(for: 10_000_000)
        mailbox.enqueue(frame(timestamp: 10_000_000))
        mailbox.enqueue(frame(timestamp: 12_000_000))
        mailbox.enqueue(frame(timestamp: 11_000_000))
        XCTAssertNil(mailbox.takeDue(at: anchor + 0.05))
        XCTAssertEqual(mailbox.takeDue(at: anchor + 0.1 + 0.000001)?.frame.timestamp, 11_000_000)
        XCTAssertNil(mailbox.takeDue(at: .infinity), "The out-of-order epoch must not retain the old future picture")

        mailbox.enqueue(frame(timestamp: 13_000_000))
        let before = CACurrentMediaTime()
        mailbox.enqueue(frame(timestamp: 0))
        let after = CACurrentMediaTime()
        let restarted = try XCTUnwrap(mailbox.takeDue(at: .infinity))
        XCTAssertEqual(restarted.frame.timestamp, 0)
        XCTAssertGreaterThanOrEqual(restarted.presentationTime, before + clock.latency)
        XCTAssertLessThanOrEqual(restarted.presentationTime, after + clock.latency)
        XCTAssertNil(mailbox.takeDue(at: .infinity))
    }

    func testClearRemovesPicturesAndByteAccountingWithoutChangingPreviewPolicy() {
        let payload = Data(count: 2048 * 2304 * 4)
        let clock = PlaybackClock()
        let mailbox = VideoMailbox(clock: clock)
        let anchor = clock.presentationTime(for: 0)
        for index in 0..<7 {
            mailbox.enqueue(frame(timestamp: Int64(index) * 200_000, width: 2048, height: 2304, data: payload))
        }
        mailbox.clear()
        XCTAssertNil(mailbox.takeDue(at: .infinity))
        for index in 10..<12 {
            mailbox.enqueue(frame(timestamp: Int64(index) * 200_000, width: 2048, height: 2304, data: payload))
        }
        XCTAssertEqual(mailbox.takeDue(at: anchor + 0.2 + 0.000001)?.frame.timestamp, 2_000_000,
                       "Stale byte accounting must not evict a fresh picture after clear")
        XCTAssertEqual(mailbox.takeDue(at: anchor + 0.22 + 0.000001)?.frame.timestamp, 2_200_000)
        mailbox.useImmediatePreview()
        mailbox.enqueue(frame(timestamp: 3_000_000))
        mailbox.clear()
        mailbox.enqueue(frame(timestamp: 4_000_000))
        XCTAssertEqual(mailbox.takeDue(at: CACurrentMediaTime())?.frame.timestamp, 4_000_000,
                       "Clear must preserve immediate-preview scheduling")
    }

    private func frame(timestamp: Int64, width: Int = 16, height: Int = 16, data: Data? = nil) -> VideoFrame {
        VideoFrame(width: width, height: height, stride: width * 4, codec: 0x41524742,
                   flags: 0, frameRateN: 50, frameRateD: 1, aspectRatio: Double(width) / Double(height),
                   colorSpace: 709, timestamp: timestamp, receivedAt: CACurrentMediaTime(),
                   data: data ?? Data(count: width * height * 4))
    }
}
