import XCTest
@testable import OMTReceiver

@MainActor
final class PlaybackRecoveryTests: XCTestCase {
    func testNamedSenderCanStopAndRestartOnAnotherPortWithResetTimestamps() async throws {
        try await withFixture(useProxies: false) { fixture in
            try await fixture.establishLiveReceivers()
            let originalSource = fixture.receiver.source
            let newPort = test_available_loopback_port()
            XCTAssertGreaterThan(newPort, 0)
            XCTAssertNotEqual(newPort, fixture.senderPort)
            fixture.stopSender()
            try await fixture.pump(until: { fixture.reconnects > 0 }, timeout: 10,
                                   failure: "Sustained sender shutdown must automatically reopen full-quality reception")
            XCTAssertEqual(fixture.receiver.source, originalSource,
                           "An outage must retain the selected discovery source")

            let beforeRestart = fixture.capture.snapshot()
            try fixture.restartSender(port: newPort)
            try await fixture.pump(until: {
                let media = fixture.capture.snapshot()
                return fixture.receiver.statusText == "Live" && media.videoTimestamp < beforeRestart.videoTimestamp &&
                    media.audioTimestamp < beforeRestart.audioTimestamp &&
                    media.video >= beforeRestart.video + 3 && media.audio >= beforeRestart.audio + 3
            }, timeout: 20, failure: "The same session must re-resolve the named sender and receive restarted video and audio")
            XCTAssertEqual(fixture.receiver.source, originalSource)
            XCTAssertEqual(fixture.senderAddress(), originalSource?.address,
                           "Discovery identity remains stable when the sender's TCP port changes")
        }
    }

    func testHalfOpenFullQualityConnectionRecoversWithoutRestartingAnotherReceiver() async throws {
        try await withFixture(useProxies: true) { fixture in
            try await fixture.establishLiveReceivers()
            let beforeLoss = fixture.capture.snapshot()
            let otherBeforeLoss = fixture.otherCapture.snapshot()
            fixture.setOffline(true)
            try await fixture.pump(until: { fixture.primaryConnections >= 4 }, timeout: 10,
                                   failure: "Complete signal loss must replace the stale video/audio pair")
            XCTAssertGreaterThan(fixture.reconnects, 0)
            let frozenConnections = fixture.primaryConnections
            fixture.setOffline(false)
            // Restoring this path never repairs old pipes: fresh connections
            // and newly received media are both required to prove recovery.
            try await fixture.pump(until: {
                let media = fixture.capture.snapshot()
                return fixture.primaryConnections > frozenConnections && fixture.receiver.statusText == "Live" &&
                    media.video > beforeLoss.video && media.audio > beforeLoss.audio &&
                    media.videoTimestamp > beforeLoss.videoTimestamp && media.audioTimestamp > beforeLoss.audioTimestamp
            }, timeout: 20, failure: "Full-quality reception must recover from half-open sockets without restarting the app")
            fixture.assertOtherReceiverContinued(since: otherBeforeLoss)
        }
    }

    func testStoppingDuringBackoffCannotReopenFullQualityReception() async throws {
        try await withFixture(useProxies: true) { fixture in
            try await fixture.establishLiveReceivers()
            let otherBeforeLoss = fixture.otherCapture.snapshot()
            fixture.setOffline(true)
            try await fixture.pump(until: { fixture.receiver.videoState == .stalled }, timeout: 8,
                                   failure: "The receiver must detect sustained signal loss")
            await fixture.stopReceiver()
            let retiredConnections = fixture.primaryConnections
            let retiredFrames = fixture.capture.snapshot()
            fixture.setOffline(false)
            try await fixture.pump(for: 5)
            XCTAssertNil(fixture.receiver.source)
            XCTAssertEqual(fixture.receiver.statusText, "Disconnected")
            XCTAssertEqual(fixture.reconnects, 0, "Stopping cancels the pending automatic retry")
            XCTAssertEqual(fixture.primaryConnections, retiredConnections)
            XCTAssertEqual(fixture.capture.snapshot().video, retiredFrames.video)
            XCTAssertEqual(fixture.capture.snapshot().audio, retiredFrames.audio)
            fixture.assertOtherReceiverContinued(since: otherBeforeLoss)
        }
    }

    func testDisconnectFromReconnectCallbackCannotCreateAnotherReceiver() async throws {
        try await withFixture(useProxies: true) { fixture in
            try await fixture.establishLiveReceivers()
            let otherBeforeLoss = fixture.otherCapture.snapshot()
            let originalConnections = fixture.primaryConnections
            fixture.disconnectOnReconnect = true
            fixture.setOffline(true)
            try await fixture.pump(until: { fixture.reconnects == 1 }, timeout: 10,
                                   failure: "The automatic reconnect must notify its owner")
            XCTAssertNil(fixture.receiver.source)
            XCTAssertEqual(fixture.receiver.statusText, "Disconnected")
            fixture.setOffline(false)
            try await fixture.pump(for: 5)
            XCTAssertEqual(fixture.reconnects, 1)
            XCTAssertEqual(fixture.primaryConnections, originalConnections,
                           "A synchronous disconnect in onReconnect must cancel replacement admission")
            fixture.assertOtherReceiverContinued(since: otherBeforeLoss)
        }
    }

    private func withFixture(useProxies: Bool, _ body: (PlaybackRecoveryFixture) async throws -> Void) async throws {
        let fixture = try PlaybackRecoveryFixture(useProxies: useProxies)
        do { try await body(fixture) }
        catch { await fixture.stop(); throw error }
        await fixture.stop()
    }
}

private final class PlaybackRecoveryCapture: @unchecked Sendable {
    struct Snapshot {
        let video: Int
        let audio: Int
        let videoTimestamp: Int64
        let audioTimestamp: Int64
    }
    private let lock = NSLock()
    private var videoFrames = 0
    private var audioFrames = 0
    private var lastVideo: Int64 = .max
    private var lastAudio: Int64 = .max
    func video(_ frame: VideoFrame) {
        lock.lock(); defer { lock.unlock() }
        videoFrames += 1; lastVideo = frame.timestamp
    }
    func audio(_ frame: AudioFrame) {
        lock.lock(); defer { lock.unlock() }
        audioFrames += 1; lastAudio = frame.timestamp
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(video: videoFrames, audio: audioFrames, videoTimestamp: lastVideo, audioTimestamp: lastAudio)
    }
}

@MainActor
private final class PlaybackRecoveryFixture {
    let receiver: ReceiverSession
    let capture: PlaybackRecoveryCapture
    let otherCapture: PlaybackRecoveryCapture
    private(set) var reconnects = 0
    var disconnectOnReconnect = false
    private(set) var senderPort: Int32
    private let library: String
    private var sender: UnsafeMutableRawPointer?
    private let primaryProxy: UnsafeMutableRawPointer?
    private let otherProxy: UnsafeMutableRawPointer?
    private let otherReceiver: ReceiverSession?
    private var timestamp: Int64 = 1_000_000_000_000
    private var receiverStopped = false
    private var otherEstablished = false
    private var unexpectedOtherStatus: String?

    var primaryConnections: Int32 { test_proxy_connections(primaryProxy) }

    init(useProxies: Bool) throws {
        XCTAssertNil(OMTSDKRuntime.shared.load())
        library = try XCTUnwrap(Bundle.main.privateFrameworksURL?.appendingPathComponent("OMT/libomt.dylib").path)
        senderPort = test_available_loopback_port()
        XCTAssertGreaterThan(senderPort, 0)
        let sender = try XCTUnwrap(test_sender_create(library, senderPort))
        var primaryProxy: UnsafeMutableRawPointer?
        var otherProxy: UnsafeMutableRawPointer?
        do {
            let source: OMTSource
            if useProxies {
                primaryProxy = try XCTUnwrap(test_proxy_create(senderPort))
                otherProxy = try XCTUnwrap(test_proxy_create(senderPort))
                source = try OMTSource.manual("omt://127.0.0.1:\(test_proxy_port(primaryProxy))")
            } else {
                let address = try Self.address(of: sender)
                source = OMTSource(id: "source:\(address)", name: address, address: address)
            }
            self.sender = sender
            self.primaryProxy = primaryProxy
            self.otherProxy = otherProxy
            let capture = PlaybackRecoveryCapture(), otherCapture = PlaybackRecoveryCapture()
            self.capture = capture
            self.otherCapture = otherCapture
            receiver = ReceiverSession(video: { capture.video($0) }, audio: { capture.audio($0) })
            if let otherProxy {
                let other = ReceiverSession(video: { otherCapture.video($0) }, audio: { otherCapture.audio($0) })
                other.connect(try OMTSource.manual("omt://127.0.0.1:\(test_proxy_port(otherProxy))"))
                otherReceiver = other
            } else { otherReceiver = nil }
            receiver.onReconnect = { [weak self] in
                guard let self else { return }
                self.reconnects += 1
                if self.disconnectOnReconnect { self.receiver.disconnect() }
            }
            receiver.connect(source)
        } catch {
            test_proxy_destroy(primaryProxy)
            test_proxy_destroy(otherProxy)
            test_sender_destroy(sender)
            throw error
        }
    }

    private static func address(of sender: UnsafeMutableRawPointer) throws -> String {
        let capacity = 4096
        var bytes = [CChar](repeating: 0, count: capacity)
        let length = test_sender_address(sender, &bytes, Int32(capacity))
        guard length > 1, Int(length) <= capacity else { throw FixtureError.address }
        return String(cString: bytes)
    }

    func senderAddress() -> String? { sender.flatMap { try? Self.address(of: $0) } }

    func establishLiveReceivers() async throws {
        try await pump(until: {
            let media = self.capture.snapshot(), other = self.otherCapture.snapshot()
            return self.receiver.statusText == "Live" && media.video >= 5 && media.audio >= 5 &&
                (self.otherReceiver == nil || (self.otherReceiver?.statusText == "Live" && other.video >= 5 && other.audio >= 5))
        }, timeout: 12, failure: "Real SDK video and audio must establish a live baseline")
        if let otherProxy {
            XCTAssertEqual(primaryConnections, 2)
            XCTAssertEqual(test_proxy_connections(otherProxy), 2)
            otherEstablished = true
        }
    }

    func stopSender() { test_sender_destroy(sender); sender = nil }

    func restartSender(port: Int32) throws {
        sender = try XCTUnwrap(test_sender_create(library, port))
        senderPort = port
        timestamp = 0
    }

    func setOffline(_ offline: Bool) { test_proxy_set_offline(primaryProxy, offline ? 1 : 0) }

    func assertOtherReceiverContinued(since before: PlaybackRecoveryCapture.Snapshot,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let after = otherCapture.snapshot()
        XCTAssertGreaterThan(after.video, before.video, file: file, line: line)
        XCTAssertGreaterThan(after.audio, before.audio, file: file, line: line)
        XCTAssertEqual(otherReceiver?.statusText, "Live", file: file, line: line)
        XCTAssertNil(unexpectedOtherStatus, "An unrelated receiver must remain Live throughout recovery", file: file, line: line)
        XCTAssertEqual(test_proxy_connections(otherProxy), 2, file: file, line: line)
    }

    func pump(until condition: () -> Bool, timeout: TimeInterval, failure: String,
              file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            try await step()
            if condition() { return }
        } while ProcessInfo.processInfo.systemUptime < deadline
        XCTFail("\(failure). Status: \(receiver.statusText); reconnects: \(reconnects); connections: \(primaryConnections)", file: file, line: line)
        throw FixtureError.timeout
    }

    func pump(for duration: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        repeat { try await step() } while ProcessInfo.processInfo.systemUptime < deadline
    }

    private func step() async throws {
        if let sender {
            _ = test_sender_video(sender, 320, 180, 0, 0, 0, timestamp)
            _ = test_sender_audio(sender, 48000, timestamp)
            timestamp += 333_667
        }
        try await Task.sleep(nanoseconds: 33_366_667)
        if otherEstablished, otherReceiver?.statusText != "Live" { unexpectedOtherStatus = otherReceiver?.statusText }
    }

    func stopReceiver() async {
        guard !receiverStopped else { return }
        receiverStopped = true
        await withCheckedContinuation { continuation in receiver.stop { continuation.resume() } }
    }

    func stop() async {
        await stopReceiver()
        if let otherReceiver { await withCheckedContinuation { continuation in otherReceiver.stop { continuation.resume() } } }
        test_proxy_destroy(primaryProxy)
        test_proxy_destroy(otherProxy)
        stopSender()
    }

    private enum FixtureError: Error { case address, timeout }
}
