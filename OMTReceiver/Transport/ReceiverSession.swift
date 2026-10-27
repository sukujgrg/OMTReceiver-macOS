import Foundation

/// Serializes cancellation against media admission: after cancel returns no old
/// frame can enter a renderer, even while a new source is being selected.
private final class ReceiveCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func admit(_ action: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if !stopped { action() }
    }
}

/// Track health follows each media channel independently. A healthy audio
/// channel must not conceal a frozen picture (or the reverse). Tracks that a
/// sender has never supplied remain optional, including audio-only sources.
struct ReceiverMediaHealth {
    struct Snapshot: Equatable {
        let status: String
        let format: String?
    }
    static let signalTimeout: TimeInterval = 3
    private let startedAt: TimeInterval
    private var lastVideo: TimeInterval?
    private var lastAudio: TimeInterval?
    private var videoFormat: String?
    private var audioFormat: String?
    private var invalidVideo: (time: TimeInterval, format: String)?

    init(startedAt: TimeInterval) { self.startedAt = startedAt }

    mutating func receivedVideo(format: String, at time: TimeInterval) {
        lastVideo = time; videoFormat = format; invalidVideo = nil
    }
    mutating func receivedAudio(format: String, at time: TimeInterval) {
        lastAudio = time; audioFormat = format
    }
    mutating func rejectedVideo(format: String, at time: TimeInterval) {
        invalidVideo = (time, format)
    }
    func snapshot(at time: TimeInterval) -> Snapshot? {
        func fresh(_ last: TimeInterval?) -> Bool {
            last.map { time - $0 <= Self.signalTimeout } ?? false
        }
        if let invalidVideo, fresh(invalidVideo.time) {
            return Snapshot(status: "Unsupported or invalid video format", format: invalidVideo.format)
        }
        let videoLive = fresh(lastVideo), audioLive = fresh(lastAudio)
        if videoLive {
            return Snapshot(status: lastAudio != nil && !audioLive ? "Audio lost — video live" : "Live", format: videoFormat)
        }
        if lastVideo != nil || invalidVideo != nil {
            return Snapshot(status: audioLive ? "Video lost — audio live" : "Signal lost — reconnecting…", format: videoFormat ?? invalidVideo?.format)
        }
        if audioLive { return Snapshot(status: "Live Audio", format: audioFormat) }
        if lastAudio != nil { return Snapshot(status: "Signal lost — reconnecting…", format: audioFormat) }
        if time - startedAt >= Self.signalTimeout { return Snapshot(status: "Waiting for sender…", format: nil) }
        return nil
    }
}

@MainActor
final class ReceiverSession {
    /// Browsing uses the SDK's reduced-resolution video channel. It never
    /// subscribes to audio, and full playback keeps its original format/rate.
    enum Mode: Sendable {
        case playback
        case preview
    }
    private(set) var source: OMTSource?
    private(set) var statusText = "Choose a source"
    private(set) var formatText = ""
    private(set) var isTerminalFailure = false
    var onChange: (() -> Void)?
    private let video: @Sendable (VideoFrame) -> Void
    private let audio: @Sendable (AudioFrame) -> Void
    private let mode: Mode
    private let queue: DispatchQueue
    private var cancellation: ReceiveCancellation?
    private var generation = UUID()

    init(video: @escaping @Sendable (VideoFrame) -> Void,
         audio: @escaping @Sendable (AudioFrame) -> Void,
         mode: Mode = .playback) {
        self.video = video; self.audio = audio; self.mode = mode
        self.queue = DispatchQueue(label: "com.suku.OMTReceiver.receive.\(UUID().uuidString)",
                                   qos: mode == .preview ? .userInitiated : .userInteractive)
    }

    func connect(_ selected: OMTSource) {
        cancellation?.cancel()
        let cancellation = ReceiveCancellation(); self.cancellation = cancellation
        let token = UUID(); generation = token
        source = selected; statusText = selected == .testPattern ? "Test Pattern" : "Connecting…"; formatText = ""
        isTerminalFailure = false
        onChange?()
        let video = self.video, audio = self.audio, mode = self.mode
        let update: @Sendable (String, String?, Bool) -> Void = { [weak self] status, format, terminal in
            // The receive queue produces an ordered stream of state changes;
            // preserve that order while crossing onto the main actor.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.statusText = status
                self.isTerminalFailure = terminal
                if let format { self.formatText = format }
                self.onChange?()
            }
        }
        queue.async {
            if cancellation.isCancelled { return }
            if selected == .testPattern {
                Self.runPattern(mode: mode, cancellation: cancellation, video: video, update: update)
            } else {
                Self.runReceiver(source: selected, mode: mode, cancellation: cancellation, video: video, audio: audio, update: update)
            }
        }
    }

    func disconnect() {
        cancellation?.cancel(); cancellation = nil; generation = UUID()
        source = nil; statusText = "Disconnected"; formatText = ""; isTerminalFailure = false; onChange?()
    }

    func reconnect() { if let source { connect(source) } }

    func stop(completion: @escaping @MainActor @Sendable () -> Void) {
        disconnect()
        queue.async { DispatchQueue.main.async(execute: completion) }
    }

    deinit { cancellation?.cancel() }

    nonisolated private static func runReceiver(source: OMTSource, mode: Mode, cancellation: ReceiveCancellation,
        video: @escaping @Sendable (VideoFrame) -> Void, audio: @escaping @Sendable (AudioFrame) -> Void,
        update: @escaping @Sendable (String, String?, Bool) -> Void) {
        if let error = OMTSDKRuntime.shared.load() { update(error, nil, true); return }
        guard !cancellation.isCancelled else { return }
        let preview: Int32 = mode == .preview ? 1 : 0
        guard let handle = omtr_receiver_create_mode(source.address, preview) else { update("The OMT SDK could not create this receiver. Try Reconnect.", nil, true); return }
        defer { omtr_receiver_destroy(handle) }
        var health = ReceiverMediaHealth(startedAt: ProcessInfo.processInfo.systemUptime)
        var lastStatus: TimeInterval = 0
        var lastSnapshot: ReceiverMediaHealth.Snapshot?
        var lastPreviewAdmission: TimeInterval = -.infinity
        var previewUnavailable = false
        while !cancellation.isCancelled {
            autoreleasepool {
                var frame = OMTRFrame()
                let found = omtr_receiver_poll_mode(handle, &frame, 100, preview)
                let now = ProcessInfo.processInfo.systemUptime
                if found != 0 {
                    if frame.type == 2 {
                        // A sender that ignores preview negotiation must not
                        // turn the source grid into multiple full-res decoders.
                        // The SDK has decoded this first frame already; retire
                        // the instance rather than repeatedly decoding/copying it.
                        if mode == .preview, frame.flags & 8 == 0 {
                            previewUnavailable = true
                            update("Preview unavailable", "This sender did not provide reduced-resolution video.", true)
                            return
                        }
                        // The SDK owns decoding. Avoid copying and queueing every
                        // incoming picture when a thumbnail only needs 15 fps.
                        if mode == .preview, now - lastPreviewAdmission < 1.0 / 15.0 {
                            return
                        }
                        if let owned = validatedVideo(frame, receivedAt: now) {
                            health.receivedVideo(format: owned.summary, at: now)
                            if mode == .preview { lastPreviewAdmission = now }
                            cancellation.admit { video(owned) }
                        } else {
                            health.rejectedVideo(format: "\(frame.width) × \(frame.height) · format 0x\(String(frame.codec, radix: 16))", at: now)
                        }
                    } else if mode == .playback, frame.type == 4, let owned = validatedAudio(frame) {
                        health.receivedAudio(format: "\(frame.channels) channels · \(frame.sampleRate) Hz", at: now)
                        cancellation.admit { audio(owned) }
                    }
                }
            }
            if previewUnavailable { return }
            let now = ProcessInfo.processInfo.systemUptime
            if let snapshot = health.snapshot(at: now), snapshot != lastSnapshot || now - lastStatus >= 1 {
                lastSnapshot = snapshot; lastStatus = now
                // The official SDK owns reconnect and discovery notifications.
                // Retaining this instance also follows virtual-source redirects.
                update(snapshot.status, snapshot.format, false)
            }
        }
    }

    /// No unchecked size products: dimensions/stride are bounded first. The
    /// accepted envelope includes UHD/8K, SD, HD and arbitrary rational rates.
    nonisolated static func validatedVideo(_ frame: OMTRFrame, receivedAt: TimeInterval) -> VideoFrame? {
        let width = Int(frame.width), height = Int(frame.height), stride = Int(frame.stride)
        let isPreview = frame.flags & 8 != 0
        let minimumDimension = isPreview ? 2 : 16
        // OMT rate terms are signed 32-bit fields. Bound the resulting rate,
        // not each term: USB cameras legitimately report 3000003/100000.
        guard (minimumDimension...8192).contains(width), (minimumDimension...8192).contains(height),
              frame.frameRateN > 0, frame.frameRateD > 0,
              Double(frame.frameRateN) / Double(frame.frameRateD) <= 240,
              stride > 0, stride <= 131072, let data = frame.data else { return nil }
        let minimumRow: Int
        let required: Int
        switch frame.codec {
        case 0x41524742, 0x58524742: // BGRA/BGRX
            minimumRow = width * 4; required = stride * height
        case 0x59565955: // UYVY
            guard width % 2 == 0 else { return nil }
            minimumRow = width * 2; required = stride * height
        case 0x41565955: // UYVA
            guard width % 2 == 0, stride == width * 2 else { return nil }
            minimumRow = width * 2; required = stride * height + width * height
        case 0x36313250: // P216
            guard width % 2 == 0 else { return nil }
            minimumRow = width * 2; required = stride * height * 2
        case 0x36314150: // PA16
            guard width % 2 == 0 else { return nil }
            minimumRow = width * 2; required = stride * height * 3
        default: return nil
        }
        guard stride >= minimumRow, required <= 256 * 1024 * 1024,
              frame.dataLength >= required, frame.colorSpace == 0 || frame.colorSpace == 601 || frame.colorSpace == 709 else { return nil }
        // The pinned SDK constructs its codec using original dimensions, then
        // returns 1/8-size preview dimensions without resolving an unspecified
        // color space. Preserve its original SD/HD matrix choice for the shader.
        // Preview height is originalHeight >> 3 (interlaced height rounds even),
        // so 90 remains the exact original-720-line boundary in either case.
        let colorSpace = isPreview && frame.colorSpace == 0 ? (height >= 90 ? 709 : 601) : Int(frame.colorSpace)
        return VideoFrame(width: width, height: height, stride: stride, codec: frame.codec,
            flags: Int(frame.flags), frameRateN: Int(frame.frameRateN), frameRateD: Int(frame.frameRateD),
            aspectRatio: Double(frame.aspectRatio), colorSpace: colorSpace, timestamp: frame.timestamp,
            receivedAt: receivedAt, data: Data(bytes: data, count: required))
    }

    nonisolated static func validatedAudio(_ frame: OMTRFrame) -> AudioFrame? {
        guard frame.codec == 0x31415046, (8000...384000).contains(frame.sampleRate),
              (1...32).contains(frame.channels), (1...131072).contains(frame.samplesPerChannel),
              let data = frame.data else { return nil }
        let required = Int(frame.channels) * Int(frame.samplesPerChannel) * MemoryLayout<Float>.size
        guard frame.dataLength >= required else { return nil }
        return AudioFrame(sampleRate: Double(frame.sampleRate), channels: Int(frame.channels),
            samplesPerChannel: Int(frame.samplesPerChannel), timestamp: frame.timestamp, data: Data(bytes: data, count: required))
    }

    nonisolated private static func runPattern(mode: Mode, cancellation: ReceiveCancellation,
        video: @escaping @Sendable (VideoFrame) -> Void, update: @escaping @Sendable (String, String?, Bool) -> Void) {
        let width = mode == .preview ? 320 : 1280
        let height = mode == .preview ? 180 : 720
        let rate: Int64 = mode == .preview ? 15 : 60
        let stride = width * 4
        let colors: [(UInt8, UInt8, UInt8)] = [(191,191,191), (0,191,191), (191,191,0), (0,191,0), (191,0,191), (0,0,191), (191,0,0)]
        var base = Data(count: stride * height)
        base.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for y in 0..<height { for x in 0..<width {
                let c = colors[min(6, x * 7 / width)], i = y * stride + x * 4
                bytes[i] = c.0; bytes[i+1] = c.1; bytes[i+2] = c.2
                // Transparent lower panel makes alpha/background inspection easy.
                bytes[i+3] = y < height * 3 / 4 ? 255 : UInt8(x * 255 / (width - 1))
            } }
        }
        let start = ProcessInfo.processInfo.systemUptime
        var index: Int64 = 0
        while !cancellation.isCancelled {
            autoreleasepool {
                var data = base
                let marker = Int(index * 4 % Int64(width))
                data.withUnsafeMutableBytes { raw in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    for y in 0..<height { for x in marker..<min(width, marker + max(2, width / 213)) {
                        let offset = y * stride + x * 4
                        bytes[offset] = 255; bytes[offset+1] = 255; bytes[offset+2] = 255; bytes[offset+3] = 255
                    } }
                }
                let frame = VideoFrame(width: width, height: height, stride: stride, codec: 0x41524742,
                    flags: mode == .preview ? 10 : 2, frameRateN: Int(rate), frameRateD: 1, aspectRatio: 16.0/9.0, colorSpace: 709,
                    timestamp: index * 10_000_000 / rate, receivedAt: ProcessInfo.processInfo.systemUptime, data: data)
                cancellation.admit { video(frame) }
                if index == 0 { update("Test Pattern", frame.summary, false) }
            }
            index += 1
            let remaining = start + Double(index) / Double(rate) - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { Thread.sleep(forTimeInterval: min(remaining, 1.0 / Double(rate))) }
            else if remaining < -0.100 { index = Int64((ProcessInfo.processInfo.systemUptime - start) * Double(rate)) }
        }
    }
}
