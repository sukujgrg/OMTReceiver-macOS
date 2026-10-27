import XCTest
@testable import OMTReceiver

@MainActor
final class ReceiverHealthTests: XCTestCase {
    func testWaitingAndSingleTrackSourcesDoNotRequireAnAbsentTrack() {
        var videoOnly = ReceiverMediaHealth(startedAt: 10)
        XCTAssertNil(videoOnly.snapshot(at: 12))
        XCTAssertEqual(videoOnly.snapshot(at: 13)?.status, "Waiting for sender…")
        XCTAssertEqual(videoOnly.snapshot(at: 13)?.videoState, .stalled)
        XCTAssertEqual(videoOnly.snapshot(at: 13)?.connectionState, .stalled)
        videoOnly.receivedVideo(format: "720p", at: 14)
        videoOnly.receivedVideo(format: "720p", at: 25)
        XCTAssertEqual(videoOnly.snapshot(at: 25)?.status, "Live", "Video-only senders must not require audio")
        XCTAssertEqual(videoOnly.snapshot(at: 25)?.videoState, .live)
        XCTAssertEqual(videoOnly.snapshot(at: 25)?.connectionState, .live)

        var audioOnly = ReceiverMediaHealth(startedAt: 0)
        audioOnly.receivedAudio(format: "2 channels · 48000 Hz", at: 1)
        XCTAssertEqual(audioOnly.snapshot(at: 2)?.status, "Live Audio")
        XCTAssertEqual(audioOnly.snapshot(at: 2)?.videoState, .waiting,
                       "An audio-only source must not be classified as a stalled video stream")
        XCTAssertEqual(audioOnly.snapshot(at: 2)?.connectionState, .live)
        XCTAssertEqual(audioOnly.snapshot(at: 5)?.status, "Signal lost — reconnecting…")
        XCTAssertEqual(audioOnly.snapshot(at: 5)?.connectionState, .stalled,
                       "An audio-only receiver must recover when its previously supplied audio stops")
    }

    func testSlowVideoCadenceDoesNotBecomeStaleBetweenExpectedFrames() {
        var health = ReceiverMediaHealth(startedAt: 0)
        // A 0.2 fps source legitimately has five seconds between pictures.
        health.receivedVideo(format: "720p · 0.2 fps", at: 1, timeout: 10)
        XCTAssertEqual(health.snapshot(at: 6)?.videoState, .live)
        XCTAssertEqual(health.snapshot(at: 6)?.connectionState, .live)
        XCTAssertEqual(health.snapshot(at: 11)?.videoState, .live)
        XCTAssertEqual(health.snapshot(at: 11)?.connectionState, .live)
        XCTAssertEqual(health.snapshot(at: 11.001)?.videoState, .stalled)
        XCTAssertEqual(health.snapshot(at: 11.001)?.connectionState, .stalled)
        health.receivedVideo(format: "720p · 0.2 fps", at: 12, timeout: 10)
        XCTAssertEqual(health.snapshot(at: 12)?.videoState, .live)
        XCTAssertEqual(health.snapshot(at: 12)?.connectionState, .live)

        var playback = ReceiverMediaHealth(startedAt: 0)
        playback.receivedVideo(format: "720p", at: 1)
        XCTAssertEqual(playback.snapshot(at: 4)?.videoState, .live)
        XCTAssertEqual(playback.snapshot(at: 4.001)?.videoState, .stalled,
                       "Video health defaults to three seconds when no slower source cadence is supplied")
    }

    func testVideoTimeoutDoesNotExtendAudioFreshness() {
        var health = ReceiverMediaHealth(startedAt: 0)
        health.receivedVideo(format: "720p · 0.2 fps", at: 1, timeout: 10)
        health.receivedAudio(format: "stereo", at: 1)
        XCTAssertEqual(health.snapshot(at: 5)?.videoState, .live)
        XCTAssertEqual(health.snapshot(at: 5)?.connectionState, .live)
        XCTAssertEqual(health.snapshot(at: 5)?.status, "Audio lost — video live",
                       "A slower video cadence must not conceal an audio interruption")
    }

    func testEachPreviouslySeenTrackLosesAndRecoversIndependently() {
        var health = ReceiverMediaHealth(startedAt: 0)
        health.receivedVideo(format: "1080p", at: 1)
        health.receivedAudio(format: "stereo", at: 1)
        health.receivedAudio(format: "stereo", at: 4.1)
        XCTAssertEqual(health.snapshot(at: 4.1)?.status, "Video lost — audio live")
        XCTAssertEqual(health.snapshot(at: 4.1)?.videoState, .stalled)
        XCTAssertEqual(health.snapshot(at: 4.1)?.connectionState, .live,
                       "Video loss must not restart a connection that is still supplying valid audio")
        XCTAssertEqual(health.snapshot(at: 4.1)?.format, "1080p", "Keep the last picture's format visible during a stall")
        health.receivedVideo(format: "1080p", at: 4.2)
        XCTAssertEqual(health.snapshot(at: 4.2)?.status, "Live")
        health.receivedVideo(format: "1080p", at: 7.2)
        XCTAssertEqual(health.snapshot(at: 7.2)?.status, "Audio lost — video live")
        XCTAssertEqual(health.snapshot(at: 7.2)?.connectionState, .live,
                       "Audio loss must not restart a connection that is still supplying valid video")
        health.receivedAudio(format: "stereo", at: 7.3)
        XCTAssertEqual(health.snapshot(at: 7.3)?.status, "Live")
        XCTAssertEqual(health.snapshot(at: 11)?.status, "Signal lost — reconnecting…")
        XCTAssertEqual(health.snapshot(at: 11)?.connectionState, .stalled)
    }

    func testInvalidVideoCannotBeHiddenByHealthyAudioAndRecoversWithValidVideo() {
        var health = ReceiverMediaHealth(startedAt: 0)
        health.receivedAudio(format: "stereo", at: 1)
        health.rejectedVideo(format: "unsupported codec", at: 1)
        XCTAssertEqual(health.snapshot(at: 1.1)?.status, "Unsupported or invalid video format")
        XCTAssertEqual(health.snapshot(at: 1.1)?.videoState, .unsupported,
                       "Continuing unsupported data must not look like an absent network stream")
        XCTAssertEqual(health.snapshot(at: 1.1)?.connectionState, .live,
                       "An invalid picture must not force reconnects while valid audio is still arriving")
        XCTAssertEqual(health.snapshot(at: 1.1)?.format, "unsupported codec")
        health.receivedAudio(format: "stereo", at: 5)
        XCTAssertEqual(health.snapshot(at: 5)?.status, "Video lost — audio live",
                       "An observed invalid video track must not later masquerade as a healthy audio-only source")
        XCTAssertEqual(health.snapshot(at: 5)?.format, "unsupported codec")
        health.receivedVideo(format: "1080p", at: 5.1)
        XCTAssertEqual(health.snapshot(at: 5.1)?.status, "Live")
    }

    func testUnsupportedVideoDoesNotCauseReconnectChurnButCompleteSilenceCanRecover() throws {
        var health = ReceiverMediaHealth(startedAt: 0)
        var backoff = ReceiverReconnectBackoff()
        for time in [1.0, 5, 10, 30] {
            health.rejectedVideo(format: "unsupported codec", at: time)
            let state = try XCTUnwrap(health.snapshot(at: time)?.connectionState)
            XCTAssertEqual(state, .unsupported)
            XCTAssertFalse(backoff.shouldReconnect(state: state, at: time),
                           "Repeated unsupported frames must remain a format error rather than resetting the transport")
        }
        XCTAssertEqual(health.snapshot(at: 33.001)?.connectionState, .stalled)
        XCTAssertFalse(backoff.shouldReconnect(state: .stalled, at: 33.001))
        XCTAssertTrue(backoff.shouldReconnect(state: .stalled, at: 34.001),
                      "When all traffic stops, ordinary bounded recovery must remain available")
    }

    func testFreshValidVideoKeepsConnectionLiveWhileInvalidFramesAreReported() {
        var health = ReceiverMediaHealth(startedAt: 0)
        health.receivedVideo(format: "720p · 0.2 fps", at: 1, timeout: 10)
        health.rejectedVideo(format: "unsupported codec", at: 5)
        XCTAssertEqual(health.snapshot(at: 5)?.videoState, .unsupported)
        XCTAssertEqual(health.snapshot(at: 5)?.connectionState, .live,
                       "A recent valid slow-cadence picture still establishes a usable connection")
        health.rejectedVideo(format: "unsupported codec", at: 12)
        XCTAssertEqual(health.snapshot(at: 12)?.connectionState, .unsupported)
    }

    func testOfficialSDKReportsVideoLossWhileAudioContinuesAndRecovers() async throws {
        XCTAssertNil(OMTSDKRuntime.shared.load())
        let library = try XCTUnwrap(Bundle.main.privateFrameworksURL?.appendingPathComponent("OMT/libomt.dylib").path)
        let port = 57000 + Int(getpid() % 5000)
        let sender = try XCTUnwrap(test_sender_create(library, Int32(port)))
        defer { test_sender_destroy(sender) }
        let session = ReceiverSession(video: { _ in }, audio: { _ in })
        session.connect(try OMTSource.manual("omt://127.0.0.1:\(port)"))

        for step in 0..<150 {
            _ = test_sender_video(sender, 320, 180, 0, 0, 0, Int64(step) * 200_000)
            _ = test_sender_audio(sender, 48000, Int64(step) * 200_000)
            try await Task.sleep(nanoseconds: 20_000_000)
            if session.statusText == "Live", !session.formatText.isEmpty { break }
        }
        let connectedStatus = session.statusText
        let originalFormat = session.formatText

        // Keep a real SDK audio connection busy beyond the video timeout.
        // The old shared lastData timestamp stayed Live throughout this phase.
        for step in 0..<220 {
            _ = test_sender_audio(sender, 48000, 100_000_000 + Int64(step) * 200_000)
            try await Task.sleep(nanoseconds: 20_000_000)
            if session.statusText == "Video lost — audio live" { break }
        }
        let stalledStatus = session.statusText
        let stalledFormat = session.formatText
        for step in 0..<100 {
            let timestamp = 200_000_000 + Int64(step) * 200_000
            _ = test_sender_video(sender, 320, 180, 0, 0, 0, timestamp)
            _ = test_sender_audio(sender, 48000, timestamp)
            try await Task.sleep(nanoseconds: 20_000_000)
            if session.statusText == "Live" { break }
        }
        let recoveredStatus = session.statusText
        await withCheckedContinuation { continuation in session.stop { continuation.resume() } }

        XCTAssertEqual(connectedStatus, "Live")
        XCTAssertTrue(originalFormat.contains("320 × 180"))
        XCTAssertEqual(stalledStatus, "Video lost — audio live")
        XCTAssertEqual(stalledFormat, originalFormat)
        XCTAssertEqual(recoveredStatus, "Live")
    }
}
