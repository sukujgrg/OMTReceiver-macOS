import AVFoundation
import Darwin
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

    func testMuteChangesTheRunningGraphWithoutWaitingForAnotherFrame() async {
        let renderer = RecordingAudioRenderer()
        let player = AudioPlayer(makeRenderer: { _, _ in renderer })
        defer { player.stop() }
        await send(frame(rate: 48000, samples: 960, channels: 2, timestamp: 0), to: player, observing: renderer)

        let muted = expectation(description: "The running renderer is muted without incoming media")
        renderer.onVolume = { if $0 == 0 { muted.fulfill() } }
        player.setMuted(true)
        await fulfillment(of: [muted], timeout: 2)
        XCTAssertEqual(renderer.snapshot().currentVolume, 0)

        let unmuted = expectation(description: "The same renderer is unmuted without incoming media")
        renderer.onVolume = { if $0 == 1 { unmuted.fulfill() } }
        player.setMuted(false)
        await fulfillment(of: [unmuted], timeout: 2)
        renderer.onVolume = nil
        XCTAssertEqual(renderer.snapshot().currentVolume, 1)
        XCTAssertEqual(renderer.snapshot().frames.count, 1)
        XCTAssertEqual(renderer.snapshot().stopCount, 0)
    }

    func testConfigurationChangeRebuildsOnlyTheAffectedGraphAndRetainsMute() async {
        let engineIdentity = NSObject(), unrelatedEngine = NSObject()
        let original = RecordingAudioRenderer(configurationObject: engineIdentity)
        let replacement = RecordingAudioRenderer()
        let creations = AudioRendererCreations()
        let player = AudioPlayer(makeRenderer: { rate, channels in
            creations.record(rate: rate, channels: channels) == 0 ? original : replacement
        })
        defer { player.stop() }
        player.setMuted(true)
        await send(frame(rate: 48000, samples: 960, channels: 2, timestamp: 0), to: player, observing: original)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: unrelatedEngine)
        await send(frame(rate: 48000, samples: 960, channels: 2, timestamp: 200_000), to: player, observing: original)
        XCTAssertEqual(creations.snapshot().count, 1)
        XCTAssertEqual(original.snapshot().stopCount, 0)

        let retired = expectation(description: "The changed output graph retires")
        original.onStop = { retired.fulfill() }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engineIdentity)
        await fulfillment(of: [retired], timeout: 2)
        await send(frame(rate: 48000, samples: 960, channels: 2, timestamp: 400_000), to: player, observing: replacement)
        XCTAssertEqual(creations.snapshot().count, 2)
        XCTAssertEqual(replacement.snapshot().volumes, [0])
        XCTAssertNil(player.errorMessage)
        XCTAssertEqual(original.snapshot().stopCount, 1)
    }

    func testRealCoreAudioRendersScheduledPCMAndMuteProducesSilence() async throws {
        let probe = CoreAudioPlaybackProbe()
        let route = probe.engine.outputNode.outputFormat(forBus: 0)
        try XCTSkipIf(route.sampleRate == 0 || route.channelCount == 0,
                      "No Core Audio output route is available; rendered audio requires a logged-in audio session.")
        let player = AudioPlayer(makeRenderer: { rate, channels in try probe.makeRenderer(rate: rate, channels: channels) })
        let stopped = expectation(description: "Real Core Audio graph is stopped")
        probe.onStop = { stopped.fulfill() }
        var timestamp: Int64 = 0
        // Observe the app's output mixer, not a microphone or the user's input.
        // A played-buffer callback proves this reaches the running hardware graph.
        let live = await pumpTone(to: player, timestamp: &timestamp) {
            let state = probe.snapshot()
            return state.completedAudible > 0 && state.peaks.suffix(2).contains { $0 > 0.001 }
        }
        let beforeMute = probe.snapshot().peaks.count
        player.setMuted(true)
        let silent = await pumpTone(to: player, timestamp: &timestamp) {
            let state = probe.snapshot()
            return state.completedMuted > 0 && state.peaks.count >= beforeMute + 3 &&
                state.peaks.suffix(3).allSatisfy { $0 < 0.000001 }
        }
        let beforeUnmute = probe.snapshot().peaks.count
        let completedBeforeUnmute = probe.snapshot().completedAudible
        player.setMuted(false)
        let resumed = await pumpTone(to: player, timestamp: &timestamp) {
            let state = probe.snapshot()
            return state.completedAudible > completedBeforeUnmute && state.peaks.count > beforeUnmute &&
                state.peaks.suffix(2).contains { $0 > 0.001 }
        }
        let error = player.errorMessage
        // The tap is test instrumentation. Remove it from the main actor before
        // retiring playback so the playback queue never waits for the
        // framework's lower-priority tap-delivery worker to finish teardown.
        await MainActor.run { probe.removeTap() }
        player.stop()
        if probe.snapshot().rendererCount > 0 { await fulfillment(of: [stopped], timeout: 3) }
        XCTAssertTrue(live, "Generated PCM must produce nonzero samples at the actual Core Audio output mixer")
        XCTAssertTrue(silent, "Muted buffers must finish playing while the output mixer produces silence")
        XCTAssertTrue(resumed, "Unmuting must restore rendered PCM on the same running graph")
        XCTAssertNil(error)
        XCTAssertEqual(probe.snapshot().rendererCount, 1, "Mute must adjust the existing graph, not replace it")
    }

    @MainActor
    func testGraphControlAndFinalReleaseStayOffTheUICallerAtFrameworkQoS() async throws {
        let executions = AudioControlExecutions()
        let first = RecordingAudioRenderer(), second = RecordingAudioRenderer()
        let creations = AudioRendererCreations()
        let graphsReleased = expectation(description: "Both graphs are released on their control lane")
        graphsReleased.expectedFulfillmentCount = 2
        var player: AudioPlayer? = AudioPlayer(makeRenderer: { rate, channels in
            executions.record("create")
            let renderer = creations.record(rate: rate, channels: channels) == 0 ? first : second
            return ExecutionObservedAudioRenderer(renderer: renderer, executions: executions,
                                                   onRelease: { graphsReleased.fulfill() })
        })
        defer { player?.stop() }

        await send(frame(rate: 48000, samples: 960, channels: 2, timestamp: 0),
                   to: try XCTUnwrap(player), observing: first)
        let muted = expectation(description: "UI mute reaches the control lane")
        first.onVolume = { if $0 == 0 { muted.fulfill() } }
        player?.setMuted(true)
        await fulfillment(of: [muted], timeout: 2)
        first.onVolume = nil

        let stopped = expectation(description: "Explicit stop retires the first graph")
        first.onStop = { stopped.fulfill() }
        player?.stop()
        await fulfillment(of: [stopped], timeout: 2)
        await send(frame(rate: 44100, samples: 882, channels: 2, timestamp: 200_000),
                   to: try XCTUnwrap(player), observing: second)

        let finalStop = expectation(description: "Last release retires the remaining graph")
        second.onStop = { finalStop.fulfill() }
        // Scheduling fulfills before drain() returns. Wait for that temporary
        // retain to end so this test exercises final release by the UI caller,
        // rather than accidentally releasing AudioPlayer on its control lane.
        // The mock has no pending completions or further notification sources.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !isKnownUniquelyReferenced(&player), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(isKnownUniquelyReferenced(&player), "The UI must hold the only remaining player reference")
        XCTAssertTrue(Thread.isMainThread, "Exercise last release from an actual UI caller")
        player = nil
        await fulfillment(of: [finalStop, graphsReleased], timeout: 2)

        let events = executions.snapshot()
        XCTAssertEqual(events.filter { $0.operation == "create" }.count, 2)
        XCTAssertEqual(events.filter { $0.operation == "stop" }.count, 2)
        XCTAssertEqual(events.filter { $0.operation == "release" }.count, 2)
        XCTAssertEqual(events.filter { $0.operation == "schedule" }.count, 2)
        for event in events {
            XCTAssertFalse(event.onMainThread, "Graph \(event.operation) must not execute on the UI caller")
            XCTAssertEqual(event.qos, QOS_CLASS_DEFAULT.rawValue,
                           "Graph \(event.operation) must use the non-real-time control lane, not inherit UI priority")
        }
    }

    @MainActor
    func testBlockedRetirementKeepsCancellationResponsiveAndCannotBeOvertakenByReplacement() async throws {
        let old = RecordingAudioRenderer(), fresh = RecordingAudioRenderer()
        let creations = AudioRendererCreations()
        let executions = AudioControlExecutions()
        let retiring = expectation(description: "Old renderer retirement entered")
        let releaseRetirement = DispatchSemaphore(value: 0)
        let freshScheduled = expectation(description: "Only the current replacement schedules")
        let player = AudioPlayer(makeRenderer: { rate, channels in
            let index = creations.record(rate: rate, channels: channels)
            executions.record(index == 0 ? "old create" : "fresh create")
            return index == 0 ? old : fresh
        })
        defer { releaseRetirement.signal(); player.stop() }
        await send(frame(rate: 48000, samples: 960, channels: 2, timestamp: 0), to: player, observing: old)
        old.onStop = {
            executions.record("old stop begin")
            retiring.fulfill()
            _ = releaseRetirement.wait(timeout: .now() + 5)
            executions.record("old stop end")
        }
        player.stop()
        await fulfillment(of: [retiring], timeout: 2)

        // The old stop is deliberately blocked. Neither UI cancellation nor
        // admission can synchronously wait for it, and replacement creation
        // must not escape onto an overlapping teardown/scheduling queue.
        XCTAssertTrue(Thread.isMainThread)
        player.enqueue(frame(rate: 32000, samples: 640, channels: 1, timestamp: 200_000))
        player.stop()
        player.setMuted(true)
        fresh.onSchedule = { executions.record("fresh schedule"); freshScheduled.fulfill() }
        player.enqueue(frame(rate: 44100, samples: 882, channels: 2, timestamp: 400_000))
        XCTAssertEqual(creations.snapshot().count, 1, "A new graph cannot overtake old graph retirement")
        XCTAssertTrue(fresh.snapshot().frames.isEmpty)
        XCTAssertEqual(old.snapshot().frames.count, 1)

        releaseRetirement.signal()
        await fulfillment(of: [freshScheduled], timeout: 2)
        fresh.onSchedule = nil
        XCTAssertEqual(creations.snapshot().map(\.0), [48000, 44100], "The canceled intermediate source never creates a graph")
        XCTAssertEqual(fresh.snapshot().frames.map(\.timestamp), [400_000])
        XCTAssertEqual(fresh.snapshot().volumes, [0])
        let events = executions.snapshot().map(\.operation)
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "old stop end")),
                          try XCTUnwrap(events.firstIndex(of: "fresh create")))
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "fresh create")),
                          try XCTUnwrap(events.firstIndex(of: "fresh schedule")))
    }

    private func pumpTone(to player: AudioPlayer, timestamp: inout Int64,
                          until condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            let offset = Int(Double(timestamp) * 48000 / 10_000_000)
            let samples = (0..<960).map { Float(0.05 * sin(Double(offset + $0) * 440 * 2 * .pi / 48000)) }
            let channels = samples + samples
            player.enqueue(AudioFrame(sampleRate: 48000, channels: 2, samplesPerChannel: 960,
                                      timestamp: timestamp, data: channels.withUnsafeBytes { Data($0) }))
            timestamp += 200_000
            try? await Task.sleep(nanoseconds: 20_000_000)
            if condition() { return true }
            if player.errorMessage != nil { return false }
        }
        return false
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

private final class AudioControlExecutions: @unchecked Sendable {
    struct Event {
        let operation: String
        let qos: UInt32
        let onMainThread: Bool
    }
    private let lock = NSLock()
    private var events: [Event] = []
    func record(_ operation: String) {
        let event = Event(operation: operation, qos: qos_class_self().rawValue, onMainThread: Thread.isMainThread)
        lock.lock(); events.append(event); lock.unlock()
    }
    func snapshot() -> [Event] { lock.lock(); defer { lock.unlock() }; return events }
}

private final class ExecutionObservedAudioRenderer: AudioRendering {
    private let renderer: RecordingAudioRenderer
    private let executions: AudioControlExecutions
    private let onRelease: @Sendable () -> Void
    init(renderer: RecordingAudioRenderer, executions: AudioControlExecutions,
         onRelease: @escaping @Sendable () -> Void) {
        self.renderer = renderer; self.executions = executions; self.onRelease = onRelease
    }
    var isRunning: Bool { executions.record("isRunning"); return renderer.isRunning }
    var configurationObject: AnyObject? { renderer.configurationObject }
    func setVolume(_ value: Float) { executions.record("volume"); renderer.setVolume(value) }
    func reset() { executions.record("reset"); renderer.reset() }
    func schedule(_ frame: AudioFrame, hostTime: Double, completion: @escaping @Sendable () -> Void) throws {
        executions.record("schedule")
        try renderer.schedule(frame, hostTime: hostTime, completion: completion)
    }
    func stop() { executions.record("stop"); renderer.stop() }
    deinit { executions.record("release"); onRelease() }
}

/// This integration probe observes the shipped renderer's real output without
/// changing the production scheduling path or accessing audio-input hardware.
private final class CoreAudioPlaybackProbe: @unchecked Sendable {
    struct Snapshot {
        var peaks: [Float] = []
        var completedAudible = 0
        var completedMuted = 0
        var rendererCount = 0
    }
    let engine = AVAudioEngine()
    private let lock = NSLock()
    private var state = Snapshot()
    private var stopCallback: (@Sendable () -> Void)?
    var onStop: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return stopCallback }
        set { lock.lock(); stopCallback = newValue; lock.unlock() }
    }

    func makeRenderer(rate: Double, channels: Int) throws -> any AudioRendering {
        let renderer = try CoreAudioRenderer(sampleRate: rate, channels: channels, engine: engine)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] buffer, _ in
            guard let planes = buffer.floatChannelData else { return }
            var peak: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                for sample in 0..<Int(buffer.frameLength) { peak = max(peak, abs(planes[channel][sample])) }
            }
            self?.record(peak: peak)
        }
        lock.lock(); state.rendererCount += 1; lock.unlock()
        return ObservedCoreAudioRenderer(renderer: renderer, probe: self)
    }
    private func record(peak: Float) { lock.lock(); state.peaks.append(peak); lock.unlock() }
    func completed(volume: Float) {
        lock.lock()
        if volume == 0 { state.completedMuted += 1 } else { state.completedAudible += 1 }
        lock.unlock()
    }
    func stopped() {
        lock.lock(); let callback = stopCallback; lock.unlock()
        callback?()
    }
    func removeTap() {
        if snapshot().rendererCount > 0 { engine.mainMixerNode.removeTap(onBus: 0) }
    }
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return state }
}

private final class ObservedCoreAudioRenderer: AudioRendering {
    private let renderer: CoreAudioRenderer
    private let probe: CoreAudioPlaybackProbe
    private var volume: Float = 1
    var isRunning: Bool { renderer.isRunning }
    var configurationObject: AnyObject? { renderer.configurationObject }
    init(renderer: CoreAudioRenderer, probe: CoreAudioPlaybackProbe) { self.renderer = renderer; self.probe = probe }
    func setVolume(_ value: Float) { volume = value; renderer.setVolume(value) }
    func reset() { renderer.reset() }
    func schedule(_ frame: AudioFrame, hostTime: Double, completion: @escaping @Sendable () -> Void) throws {
        let volume = volume
        try renderer.schedule(frame, hostTime: hostTime) { [probe] in
            probe.completed(volume: volume)
            completion()
        }
    }
    func stop() { renderer.stop(); probe.stopped() }
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
        var currentVolume: Float = 1
    }
    private let lock = NSLock()
    private var state = Snapshot()
    private var volume: Float = 1
    private var pendingDuration = 0.0
    private var completions: [@Sendable () -> Void] = []
    private var scheduleCallback: (@Sendable () -> Void)?
    private var stopCallback: (@Sendable () -> Void)?
    private var volumeCallback: (@Sendable (Float) -> Void)?
    var failScheduling = false
    var isRunning: Bool { true }
    let configurationObject: AnyObject?
    init(configurationObject: AnyObject? = nil) { self.configurationObject = configurationObject }
    var onSchedule: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return scheduleCallback }
        set { lock.lock(); scheduleCallback = newValue; lock.unlock() }
    }
    var onStop: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return stopCallback }
        set { lock.lock(); stopCallback = newValue; lock.unlock() }
    }
    var onVolume: (@Sendable (Float) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return volumeCallback }
        set { lock.lock(); volumeCallback = newValue; lock.unlock() }
    }
    func setVolume(_ value: Float) {
        lock.lock(); volume = value; state.currentVolume = value
        let callback = volumeCallback; lock.unlock()
        callback?(value)
    }
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
