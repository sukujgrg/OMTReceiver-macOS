import XCTest
@testable import OMTReceiver

final class TransportValidationTests: XCTestCase {
    private func video(codec: UInt32 = 0x59565955, width: Int32 = 1920, height: Int32 = 1080,
                       stride: Int32 = 3840, flags: Int32 = 0, bytes: Int,
                       inspect: (OMTRFrame) -> Void) {
        let storage = Data(repeating: 71, count: bytes)
        storage.withUnsafeBytes { buffer in
            var frame = OMTRFrame()
            frame.type = 2; frame.timestamp = 123456789
            frame.codec = codec; frame.width = width; frame.height = height; frame.stride = stride
            frame.flags = flags; frame.frameRateN = 30000; frame.frameRateD = 1001
            frame.colorSpace = 709; frame.aspectRatio = 16.0 / 9.0
            frame.data = buffer.baseAddress; frame.dataLength = Int32(bytes)
            inspect(frame)
        }
    }

    func testInterlacedRationalRateAndTimestampArePreserved() {
        video(flags: 1, bytes: 3840 * 1080) { raw in
            let frame = ReceiverSession.validatedVideo(raw, receivedAt: 42)
            XCTAssertEqual(frame?.frameRateN, 30000)
            XCTAssertEqual(frame?.frameRateD, 1001)
            XCTAssertEqual(frame?.timestamp, 123456789)
            XCTAssertEqual(frame?.receivedAt, 42)
            XCTAssertEqual(frame?.isInterlaced, true)
            XCTAssertEqual(frame?.data.count, 3840 * 1080)
        }
    }

    func testSDKUYVAAlphaPlaneIsRequiredAndOwned() {
        var saved: VideoFrame?
        video(codec: 0x41565955, flags: 2, bytes: 3840 * 1080 + 1920 * 1080) { raw in
            saved = ReceiverSession.validatedVideo(raw, receivedAt: 0)
            var truncated = raw; truncated.dataLength -= 1
            XCTAssertNil(ReceiverSession.validatedVideo(truncated, receivedAt: 0))
        }
        XCTAssertEqual(saved?.hasAlpha, true)
        XCTAssertEqual(saved?.data.last, 71)
    }

    func testHighBitDepthPlanesArePreservedWithoutConversion() {
        for (codec, planes) in [(UInt32(0x36313250), 2), (UInt32(0x36314150), 3)] {
            video(codec: codec, flags: planes == 3 ? 18 : 16, bytes: 3840 * 1080 * planes) { raw in
                let frame = ReceiverSession.validatedVideo(raw, receivedAt: 0)
                XCTAssertEqual(frame?.codec, codec)
                XCTAssertEqual(frame?.data.count, 3840 * 1080 * planes)
                var truncated = raw; truncated.dataLength -= 1
                XCTAssertNil(ReceiverSession.validatedVideo(truncated, receivedAt: 0))
            }
        }
    }

    func testInvalidStrideRateColorAndOversizedFramesAreRejected() {
        video(bytes: 3840 * 1080) { raw in
            var invalid = raw
            invalid.stride = 12
            XCTAssertNil(ReceiverSession.validatedVideo(invalid, receivedAt: 0))
            invalid = raw; invalid.frameRateD = 0
            XCTAssertNil(ReceiverSession.validatedVideo(invalid, receivedAt: 0))
            invalid = raw; invalid.width = Int32.max; invalid.height = Int32.max
            XCTAssertNil(ReceiverSession.validatedVideo(invalid, receivedAt: 0))
            invalid = raw; invalid.colorSpace = 2020
            XCTAssertNil(ReceiverSession.validatedVideo(invalid, receivedAt: 0))
            invalid = raw; invalid.data = nil
            XCTAssertNil(ReceiverSession.validatedVideo(invalid, receivedAt: 0))
        }
    }

    func testNativeSDAndUHDHaveNoHDResolutionClamp() {
        for (width, height) in [(720, 576), (3840, 2160)] {
            video(width: Int32(width), height: Int32(height), stride: Int32(width * 2), bytes: width * height * 2) { raw in
                var frame = raw; frame.frameRateN = 60000; frame.frameRateD = 1001
                XCTAssertEqual(ReceiverSession.validatedVideo(frame, receivedAt: 0)?.width, width)
            }
        }
    }

    func testPCMAdmits44100And96000PlanarAudioAndRejectsTruncation() {
        for sampleRate in [44100, 96000] {
            var values = [Float](repeating: 0, count: 128 * 2)
            values[0] = 0.25; values[128] = -0.5
            values.withUnsafeBytes { bytes in
                var raw = OMTRFrame()
                raw.type = 4; raw.codec = 0x31415046
                raw.sampleRate = Int32(sampleRate); raw.channels = 2; raw.samplesPerChannel = 128
                raw.timestamp = 777; raw.data = bytes.baseAddress; raw.dataLength = Int32(bytes.count)
                let audio = ReceiverSession.validatedAudio(raw)
                XCTAssertEqual(audio?.sampleRate, Double(sampleRate))
                XCTAssertEqual(audio?.timestamp, 777)
                XCTAssertEqual(audio?.data.count, bytes.count)
                raw.dataLength -= 1
                XCTAssertNil(ReceiverSession.validatedAudio(raw))
            }
        }
    }
}
