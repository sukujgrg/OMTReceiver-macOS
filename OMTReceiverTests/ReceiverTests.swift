import XCTest
import QuartzCore
@testable import OMTReceiver

final class ModelTests: XCTestCase {
    func testManualAddressValidation() throws {
        for good in ["omt://192.168.1.20:6400", "sender.local:6500", "omt://[::1]:6400"] {
            XCTAssertTrue(try OMTSource.manual(good).address.hasPrefix("omt://"))
        }
        for bad in ["", "sender.local", "omt://host:0", "omt://host:65536", "http://host:6400", "omt://user@host:6400", "omt://host:6400/path", "omt://host:6400?x=1", "omt://host:6400#fragment", "omt://host name:6400"] {
            XCTAssertThrowsError(try OMTSource.manual(bad), bad)
        }
    }
    func testRationalClockPreservesNTSCCadenceAndAVOffset() {
        let clock = PlaybackClock()
        let first = clock.presentationTime(for: 10_000_000)
        let second = clock.presentationTime(for: 10_333_667)
        XCTAssertEqual(second-first, 1001.0/30000, accuracy: 0.0000001)
        XCTAssertEqual(clock.presentationTime(for: 10_100_000)-first, 0.01, accuracy: 0.0000001)
        XCTAssertGreaterThan(first, CACurrentMediaTime())
    }
    func testClockReanchorsAfterSenderRestart() {
        let clock = PlaybackClock()
        _ = clock.presentationTime(for: 100_000_000_000)
        let restarted = clock.presentationTime(for: 0)
        XCTAssertEqual(restarted-CACurrentMediaTime(), clock.latency, accuracy: 0.01)
        clock.reset()
        let remapped = clock.presentationTime(for: Int64.max - 1)
        XCTAssertTrue(remapped.isFinite)
    }
    @MainActor func testPreferencesPersistIndependentValues() {
        let name = "OMTReceiver.tests.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        let first=Preferences(defaults:defaults)
        XCTAssertEqual(first.deinterlace,.automatic)
        first.fullscreenDisplayID="display-uuid"; first.background = .checkerboard
        first.deinterlace = .bob; first.fieldOrder = .bottomFirst
        let restored=Preferences(defaults:defaults)
        XCTAssertEqual(restored.fullscreenDisplayID,"display-uuid")
        XCTAssertEqual(restored.background,.checkerboard)
        XCTAssertEqual(restored.deinterlace,.bob)
        XCTAssertEqual(restored.fieldOrder,.bottomFirst)
    }
}

private final class MediaCapture: @unchecked Sendable {
    private let lock=NSLock()
    private var frames:[VideoFrame]=[]
    private var audio:[AudioFrame]=[]
    func video(_ frame:VideoFrame) { lock.lock(); defer { lock.unlock() }; if frames.count < 20 { frames.append(frame) } }
    func audio(_ frame:AudioFrame) { lock.lock(); defer { lock.unlock() }; if audio.count < 20 { audio.append(frame) } }
    func snapshot()->([VideoFrame],[AudioFrame]) { lock.lock(); defer { lock.unlock() }; return (frames,audio) }
}

@MainActor final class SDKLoopbackTests: XCTestCase {
    func testOfficialSDKConcurrentReceiversAlphaInterlaceDepthAndAudio() async throws {
        XCTAssertNil(OMTSDKRuntime.shared.load())
        let path=try XCTUnwrap(Bundle.main.privateFrameworksURL?.appendingPathComponent("OMT/libomt.dylib").path)
        let port=23000+Int(getpid()%10000)
        let sender=try XCTUnwrap(test_sender_create(path,Int32(port)))
        defer { test_sender_destroy(sender) }
        for (index,config) in [(640,480,true,false,false,44100),(1280,720,false,true,false,48000),(640,360,false,true,true,48000)].enumerated() {
            let (w,h,interlaced,alpha,depth,sampleRate)=config
            let a=MediaCapture(), b=MediaCapture()
            let one=ReceiverSession(video:{ a.video($0) },audio:{ a.audio($0) })
            let two=ReceiverSession(video:{ b.video($0) },audio:{ b.audio($0) })
            let source=try OMTSource.manual("omt://127.0.0.1:\(port)")
            one.connect(source); two.connect(source)
            for step in 0..<100 {
                let stamp=Int64(index)*100_000_000 + Int64(step)*200_000
                _=test_sender_video(sender,Int32(w),Int32(h),interlaced ? 1:0,alpha ? 1:0,depth ? 1:0,stamp)
                _=test_sender_audio(sender,Int32(sampleRate),stamp)
                try await Task.sleep(nanoseconds:20_000_000)
                if a.snapshot().0.count>=3 && b.snapshot().0.count>=3 && !a.snapshot().1.isEmpty && !b.snapshot().1.isEmpty { break }
            }
            for capture in [a,b] {
                let (video,audio)=capture.snapshot()
                XCTAssertGreaterThanOrEqual(video.count,3,"Missing video: \(one.statusText)")
                let frame=try XCTUnwrap(video.first)
                XCTAssertEqual(frame.width,w); XCTAssertEqual(frame.height,h)
                XCTAssertEqual(frame.isInterlaced,interlaced); XCTAssertEqual(frame.hasAlpha,alpha)
                XCTAssertEqual(frame.frameRateD,1001)
                if depth { XCTAssertEqual(frame.flags & 16,16); XCTAssertEqual(frame.codec,0x36314150) }
                let pcm=try XCTUnwrap(audio.first)
                XCTAssertEqual(pcm.sampleRate,Double(sampleRate)); XCTAssertEqual(pcm.channels,2)
                XCTAssertEqual(pcm.data.count,pcm.samplesPerChannel*pcm.channels*4)
            }
            await withCheckedContinuation { continuation in one.stop { continuation.resume() } }
            await withCheckedContinuation { continuation in two.stop { continuation.resume() } }
        }
    }
    func testSDKRecoversAfterSenderRestartWithSameReceiver() async throws {
        XCTAssertNil(OMTSDKRuntime.shared.load())
        let path=try XCTUnwrap(Bundle.main.privateFrameworksURL?.appendingPathComponent("OMT/libomt.dylib").path)
        let port=34000+Int(getpid()%10000)
        var sender=test_sender_create(path,Int32(port))
        XCTAssertNotNil(sender)
        defer { if let sender { test_sender_destroy(sender) } }
        let capture=MediaCapture()
        let session=ReceiverSession(video:{capture.video($0)},audio:{capture.audio($0)})
        session.connect(try OMTSource.manual("omt://127.0.0.1:\(port)"))
        for step in 0..<150 {
            _=test_sender_video(sender,320,180,0,0,0,Int64(step)*200_000)
            try await Task.sleep(nanoseconds:20_000_000)
            if !capture.snapshot().0.isEmpty { break }
        }
        XCTAssertFalse(capture.snapshot().0.isEmpty)
        test_sender_destroy(sender); sender=nil
        try await Task.sleep(nanoseconds:200_000_000)
        sender=test_sender_create(path,Int32(port))
        XCTAssertNotNil(sender)
        var recovered=false
        for step in 0..<600 {
            _=test_sender_video(sender,320,180,0,0,0,200_000_000+Int64(step)*200_000)
            try await Task.sleep(nanoseconds:20_000_000)
            if capture.snapshot().0.contains(where:{$0.timestamp>=200_000_000}) { recovered=true; break }
        }
        XCTAssertTrue(recovered,"Retained receiver failed to recover from sender restart")
        await withCheckedContinuation { c in session.stop { c.resume() } }
    }
    func testPatternAndRapidSourceRetirement() async throws {
        let capture=MediaCapture()
        let ready = expectation(description: "Pattern received after rapid cancellation")
        let session=ReceiverSession(video:{ frame in
            let first = capture.snapshot().0.isEmpty
            capture.video(frame)
            if first { ready.fulfill() }
        },audio:{capture.audio($0)})
        for _ in 0..<10 { session.connect(.testPattern); session.disconnect() }
        session.connect(.testPattern)
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertFalse(capture.snapshot().0.isEmpty)
        await withCheckedContinuation { continuation in session.stop { continuation.resume() } }
        XCTAssertNil(session.source)
    }
}
