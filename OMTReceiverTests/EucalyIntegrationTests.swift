import AppKit
import XCTest
@testable import OMTReceiver

@MainActor final class EucalyIntegrationTests: XCTestCase {
    func testEucalyProductionVideoAudioAndDiscovery() async throws {
        guard let address = ProcessInfo.processInfo.environment["OMT_EUCALY_TEST_ADDRESS"] else {
            throw XCTSkip("Opt in with TEST_RUNNER_OMT_EUCALY_TEST_ADDRESS pointing to an isolated eucaly OMT sender.")
        }
        let source=try OMTSource.manual(address)
        let clock=PlaybackClock()
        let view=VideoView(clock:clock)
        let audio=AudioPlayer(clock:clock); audio.setMuted(true)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:360),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false; window.contentView=view; window.orderFront(nil)
        let ready=expectation(description:"eucaly video and PCM received")
        ready.expectedFulfillmentCount=2
        let capture=EucalyCapture(ready:ready)
        let session=ReceiverSession(video:{ frame in capture.video(frame); view.enqueue(frame) },audio:{ frame in capture.audio(frame); audio.enqueue(frame) })
        session.connect(source)
        await fulfillment(of:[ready],timeout:15)
        let (video,pcm)=capture.snapshot()
        XCTAssertEqual(video?.width,1920); XCTAssertEqual(video?.height,1080)
        XCTAssertEqual(video?.frameRateN,30); XCTAssertEqual(video?.frameRateD,1)
        XCTAssertEqual(video?.colorSpace,709); XCTAssertEqual(video?.isInterlaced,false)
        XCTAssertEqual(pcm?.sampleRate,48000); XCTAssertEqual(pcm?.channels,2)
        // Allow the ordinary display loop to present the admitted source picture.
        let deadline=Date().addingTimeInterval(3)
        while view.displayedFormat == nil && Date()<deadline { try await Task.sleep(nanoseconds:20_000_000) }
        XCTAssertNil(view.errorMessage)
        XCTAssertNotNil(view.displayedFormat)
        let discovery=OMTDiscoveryManager(); discovery.start()
        let discoverUntil=Date().addingTimeInterval(6)
        while !discovery.sources.contains(where:{$0.name.contains("eucaly Production Stress")}) && Date()<discoverUntil {
            try await Task.sleep(nanoseconds:50_000_000)
        }
        XCTAssertTrue(discovery.sources.contains(where:{$0.name.contains("eucaly Production Stress")}),discovery.statusText)
        await withCheckedContinuation { c in discovery.stop { c.resume() } }
        await withCheckedContinuation { c in session.stop { c.resume() } }
        audio.stop(); view.clear(); window.close()
    }
}
private final class EucalyCapture: @unchecked Sendable {
    private let lock=NSLock()
    private var firstVideo:VideoFrame?
    private var firstAudio:AudioFrame?
    private let ready:XCTestExpectation
    init(ready:XCTestExpectation) { self.ready=ready }
    func video(_ f:VideoFrame) { lock.lock(); defer{lock.unlock()}; if firstVideo==nil { firstVideo=f; ready.fulfill() } }
    func audio(_ f:AudioFrame) { lock.lock(); defer{lock.unlock()}; if firstAudio==nil { firstAudio=f; ready.fulfill() } }
    func snapshot()->(VideoFrame?,AudioFrame?) { lock.lock(); defer{lock.unlock()}; return(firstVideo,firstAudio) }
}
