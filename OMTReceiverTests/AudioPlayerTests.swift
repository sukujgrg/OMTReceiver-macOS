import Foundation
import XCTest
@testable import OMTReceiver

final class AudioPlayerTests: XCTestCase {
    func testLongPlanarChunksKeepNewestAlignedSamplesAtEverySupportedRate() throws {
        for rate in [8000.0, 44100, 48000, 96000, 384000] {
            let original = frame(rate: rate, samples: 131072, channels: 3, timestamp: 1000)
            let admitted = try XCTUnwrap(AudioFrameQueue.normalized(original))
            let kept = Int(floor(rate * 0.300))
            XCTAssertTrue(admitted.trimmed)
            XCTAssertEqual(admitted.frame.samplesPerChannel, kept)
            XCTAssertLessThanOrEqual(admitted.frame.duration, 0.300)
            XCTAssertEqual(admitted.frame.data.count, kept * 3 * 4)
            let omitted = original.samplesPerChannel - kept
            let expectedTicks = Int64((Double(omitted) * 10_000_000 / rate).rounded())
            XCTAssertEqual(admitted.frame.timestamp, original.timestamp + expectedTicks)
            let values = floats(admitted.frame.data)
            for channel in 0..<3 {
                XCTAssertEqual(values[channel * kept], Float(channel * 1_000_000 + omitted))
                XCTAssertEqual(values[(channel + 1) * kept - 1], Float(channel * 1_000_000 + original.samplesPerChannel - 1))
            }
        }
        let ordinary = frame(rate: 48000, samples: 1024, channels: 2, timestamp: 0)
        let untrimmed = try XCTUnwrap(AudioFrameQueue.normalized(ordinary))
        XCTAssertFalse(untrimmed.trimmed)
        XCTAssertEqual(untrimmed.frame.data, ordinary.data)
        XCTAssertEqual(untrimmed.frame.timestamp, ordinary.timestamp)
        let overflow = frame(rate: 8000, samples: 8000, channels: 1, timestamp: Int64.max - 1)
        XCTAssertEqual(AudioFrameQueue.normalized(overflow)?.frame.timestamp, Int64.max)
    }

    func testBacklogKeepsNewestWindowWithinBothDurationAndPacketBounds() throws {
        var queue = AudioFrameQueue()
        for index in 0..<100 {
            let input = frame(rate: 8000, samples: 20, channels: 1, timestamp: Int64(index))
            _ = queue.append(try XCTUnwrap(AudioFrameQueue.normalized(input)).frame)
            XCTAssertLessThanOrEqual(queue.frames.count, 32)
            XCTAssertLessThanOrEqual(queue.duration, 0.300)
        }
        XCTAssertEqual(queue.frames.count, 32)
        XCTAssertEqual(queue.frames.first?.timestamp, 68)
        XCTAssertEqual(queue.frames.last?.timestamp, 99)
        let long = try XCTUnwrap(AudioFrameQueue.normalized(frame(rate: 8000, samples: 131072, channels: 2, timestamp: 10_000)))
        XCTAssertTrue(queue.append(long.frame))
        XCTAssertEqual(queue.frames.count, 1)
        XCTAssertEqual(queue.frames.first?.timestamp, long.frame.timestamp)
        XCTAssertLessThanOrEqual(queue.duration, 0.300)
        XCTAssertEqual(queue.takeAll().count, 1)
        XCTAssertTrue(queue.frames.isEmpty)
        XCTAssertEqual(queue.duration, 0)
    }

    func testSchedulingBudgetResetsBeforeOverflowAndIgnoresOldCompletionEpochs() async throws {
        let renderer = RecordingAudioRenderer()
        let player = AudioPlayer(makeRenderer: { _, _ in renderer })
        defer { player.stop() }
        for index in 0..<4 {
            await send(frame(rate: 8000, samples: 800, channels: 2, timestamp: Int64(index) * 1_000_000),
                       to: player, observing: renderer)
        }
        XCTAssertEqual(renderer.snapshot().resetCount, 1)
        // These belonged to the graph's first scheduling epoch. If they reduced
        // the new epoch's accounting, later buffers could exceed 350 ms.
        renderer.complete(Array(0..<3))
        for index in 4..<7 {
            await send(frame(rate: 8000, samples: 800, channels: 2, timestamp: Int64(index) * 1_000_000),
                       to: player, observing: renderer)
        }
        let result = renderer.snapshot()
        XCTAssertEqual(result.frames.count, 7)
        XCTAssertEqual(result.resetCount, 2)
        XCTAssertLessThanOrEqual(result.maximumPendingDuration, 0.350)
        XCTAssertTrue(result.hostTimes.allSatisfy(\.isFinite))
    }

    func testStopFencesAFrameWhoseRendererWasStillBeingPrepared() async throws {
        let entered = expectation(description: "Old renderer preparation entered")
        let stopped = expectation(description: "Old renderer retired after cancellation")
        let release = DispatchSemaphore(value: 0)
        let old = RecordingAudioRenderer()
        old.onStop = { stopped.fulfill() }
        let fresh = RecordingAudioRenderer()
        let creations = AudioRendererCreations()
        let player = AudioPlayer(makeRenderer: { rate, channels in
            let index = creations.record(rate: rate, channels: channels)
            if index == 0 {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return old
            }
            return fresh
        })
        defer { release.signal(); player.stop() }
        player.enqueue(frame(rate: 48000, samples: 1024, channels: 2, timestamp: 0))
        await fulfillment(of: [entered], timeout: 2)
        player.stop()
        release.signal()
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertTrue(old.snapshot().frames.isEmpty, "A cancelled source must not reach Core Audio after graph preparation")
        player.setMuted(true)
        await send(frame(rate: 44100, samples: 1024, channels: 1, timestamp: 1_000_000),
                   to: player, observing: fresh)
        XCTAssertEqual(creations.snapshot().map(\.0), [48000, 44100])
        XCTAssertEqual(creations.snapshot().map(\.1), [2, 1])
        XCTAssertEqual(fresh.snapshot().volumes, [0])
    }

    func testRendererFailureReleasesAdmissionFenceAndCanRecover() async throws {
        let failed = expectation(description: "Renderer failure reported")
        let recovered = expectation(description: "Successful playback clears the current error")
        let broken = RecordingAudioRenderer()
        broken.failScheduling = true
        let healthy = RecordingAudioRenderer()
        let creations = AudioRendererCreations()
        let player = AudioPlayer(makeRenderer: { rate, channels in
            creations.record(rate: rate, channels: channels) == 0 ? broken : healthy
        })
        player.onStateChange = { [weak player] in
            if player?.errorMessage != nil { failed.fulfill() }
            else { recovered.fulfill() }
        }
        defer { player.stop() }
        player.enqueue(frame(rate: 48000, samples: 1024, channels: 2, timestamp: 0))
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertNotNil(player.errorMessage)
        // A sender continues delivering after a transient device failure. The
        // next chunk must retry, release the old fence and clear stale UI error.
        await send(frame(rate: 48000, samples: 1024, channels: 2, timestamp: 1_000_000),
                   to: player, observing: healthy)
        await fulfillment(of: [recovered], timeout: 2)
        XCTAssertNil(player.errorMessage)
        XCTAssertEqual(healthy.snapshot().frames.count, 1)
        XCTAssertEqual(broken.snapshot().stopCount, 1)
    }

    func testCancelledPreparationFailureCannotPublishIntoTheNextSource() async throws {
        let entered = expectation(description: "Cancelled renderer preparation entered")
        let release = DispatchSemaphore(value: 0)
        let healthy = RecordingAudioRenderer()
        let creations = AudioRendererCreations()
        let changes = DeferredAudioHealthObserver()
        let player = AudioPlayer(makeRenderer: { rate, channels in
            if creations.record(rate: rate, channels: channels) == 0 {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
                throw NSError(domain: "AudioPlayerTests.Cancelled", code: 1)
            }
            return healthy
        })
        player.onStateChange = { [weak player] in if let player { changes.notify(player) } }
        defer { release.signal(); player.stop() }
        player.enqueue(frame(rate: 48000, samples: 1024, channels: 2, timestamp: 0))
        await fulfillment(of: [entered], timeout: 2)
        player.stop()
        release.signal()
        await send(frame(rate: 44100, samples: 1024, channels: 1, timestamp: 2_000_000),
                   to: player, observing: healthy)
        XCTAssertNil(player.errorMessage)
        XCTAssertTrue(changes.readCurrentStates().isEmpty, "A retired source cannot publish error or recovery state into its successor")
    }

    func testDelayedHealthNotificationsReadTheCurrentSourceStateAfterStop() async throws {
        let failed = expectation(description: "Error state exists before main-actor delivery")
        let renderer = RecordingAudioRenderer()
        renderer.failScheduling = true
        let changes = DeferredAudioHealthObserver()
        let player = AudioPlayer(makeRenderer: { _, _ in renderer })
        player.onStateChange = { [weak player] in
            guard let player else { return }
            changes.notify(player)
            if player.errorMessage != nil { failed.fulfill() }
        }
        player.enqueue(frame(rate: 48000, samples: 1024, channels: 2, timestamp: 0))
        await fulfillment(of: [failed], timeout: 2)
        player.stop()
        let delivered = changes.readCurrentStates()
        XCTAssertEqual(delivered.count, 2, "Only error and clearing transitions notify")
        XCTAssertTrue(delivered.allSatisfy { $0 == nil }, "A delayed main-actor signal must read cleared current state, not replay its old error")
    }

    private func send(_ frame: AudioFrame, to player: AudioPlayer, observing renderer: RecordingAudioRenderer) async {
        let scheduled = expectation(description: "PCM scheduled")
        renderer.onSchedule = { scheduled.fulfill() }
        player.enqueue(frame)
        await fulfillment(of: [scheduled], timeout: 2)
        renderer.onSchedule = nil
    }

    private func frame(rate: Double, samples: Int, channels: Int, timestamp: Int64) -> AudioFrame {
        let values = (0..<(samples * channels)).map { offset in
            Float((offset / samples) * 1_000_000 + offset % samples)
        }
        let data = values.withUnsafeBytes { Data($0) }
        return AudioFrame(sampleRate: rate, channels: channels, samplesPerChannel: samples, timestamp: timestamp, data: data)
    }

    private func floats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { bytes in
            (0..<(bytes.count / 4)).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
    }
}

private final class DeferredAudioHealthObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [@Sendable () -> String?] = []
    func notify(_ player: AudioPlayer) {
        lock.lock(); reads.append { [weak player] in player?.errorMessage }; lock.unlock()
    }
    func readCurrentStates() -> [String?] {
        lock.lock(); let pending = reads; reads.removeAll(); lock.unlock()
        return pending.map { $0() }
    }
}

private final class AudioRendererCreations: @unchecked Sendable {
    private let lock = NSLock()
    private var formats: [(Double, Int)] = []
    @discardableResult func record(rate: Double, channels: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let index = formats.count
        formats.append((rate, channels))
        return index
    }
    func snapshot() -> [(Double, Int)] { lock.lock(); defer { lock.unlock() }; return formats }
}

private final class RecordingAudioRenderer: AudioRendering, @unchecked Sendable {
    struct Snapshot {
        var frames: [AudioFrame] = []
        var hostTimes: [Double] = []
        var volumes: [Float] = []
        var resetCount = 0
        var stopCount = 0
        var maximumPendingDuration = 0.0
    }
    private let lock = NSLock()
    private var state = Snapshot()
    private var volume: Float = 1
    private var pendingDuration = 0.0
    private var completions: [@Sendable () -> Void] = []
    private var scheduleCallback: (@Sendable () -> Void)?
    private var stopCallback: (@Sendable () -> Void)?
    var failScheduling = false
    var isRunning: Bool { true }
    var configurationObject: AnyObject? { nil }
    var onSchedule: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return scheduleCallback }
        set { lock.lock(); scheduleCallback = newValue; lock.unlock() }
    }
    var onStop: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return stopCallback }
        set { lock.lock(); stopCallback = newValue; lock.unlock() }
    }
    func setVolume(_ value: Float) { lock.lock(); volume = value; lock.unlock() }
    func reset() { lock.lock(); state.resetCount += 1; pendingDuration = 0; lock.unlock() }
    func schedule(_ frame: AudioFrame, hostTime: Double, completion: @escaping @Sendable () -> Void) throws {
        if failScheduling { throw NSError(domain: "AudioPlayerTests", code: 1) }
        lock.lock()
        state.frames.append(frame); state.hostTimes.append(hostTime); state.volumes.append(volume)
        pendingDuration += frame.duration
        state.maximumPendingDuration = max(state.maximumPendingDuration, pendingDuration)
        completions.append(completion)
        let callback = scheduleCallback
        lock.unlock()
        callback?()
    }
    func stop() {
        lock.lock(); state.stopCount += 1; pendingDuration = 0
        let callback = stopCallback
        lock.unlock()
        callback?()
    }
    func complete(_ indices: [Int]) {
        lock.lock(); let callbacks = indices.map { completions[$0] }; lock.unlock()
        callbacks.forEach { $0() }
    }
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return state }
}
