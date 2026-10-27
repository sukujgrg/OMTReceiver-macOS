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
        onChange?()
        let video = self.video, audio = self.audio, mode = self.mode
        let update: @Sendable (String, String?) -> Void = { [weak self] status, format in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.statusText = status
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
        source = nil; statusText = "Disconnected"; formatText = ""; onChange?()
    }

    func reconnect() { if let source { connect(source) } }

    func stop(completion: @escaping @MainActor @Sendable () -> Void) {
        disconnect()
        queue.async { DispatchQueue.main.async(execute: completion) }
    }

    deinit { cancellation?.cancel() }

    nonisolated private static func runReceiver(source: OMTSource, mode: Mode, cancellation: ReceiveCancellation,
        video: @escaping @Sendable (VideoFrame) -> Void, audio: @escaping @Sendable (AudioFrame) -> Void,
        update: @escaping @Sendable (String, String?) -> Void) {
        if let error = OMTSDKRuntime.shared.load() { update(error, nil); return }
        guard !cancellation.isCancelled else { return }
        let preview: Int32 = mode == .preview ? 1 : 0
        guard let handle = omtr_receiver_create_mode(source.address, preview) else { update("The OMT SDK could not create this receiver. Try Reconnect.", nil); return }
        defer { omtr_receiver_destroy(handle) }
        var lastData = ProcessInfo.processInfo.systemUptime
        var lastStatus: TimeInterval = 0
        var summary = ""
        var receivedVideo = false
        var hadMedia = false
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
                            update("Preview unavailable", "This sender did not provide reduced-resolution video.")
                            return
                        }
                        // The SDK owns decoding. Avoid copying and queueing every
                        // incoming picture when a thumbnail only needs 15 fps.
                        if mode == .preview, now - lastPreviewAdmission < 1.0 / 15.0 {
                            lastData = now
                            return
                        }
                        if let owned = validatedVideo(frame, receivedAt: now) {
                            lastData = now; hadMedia = true; receivedVideo = true
                            if mode == .preview { lastPreviewAdmission = now }
                            cancellation.admit { video(owned) }
                            let newSummary = owned.summary
                            if newSummary != summary || now - lastStatus >= 1 {
                                summary = newSummary; lastStatus = now; update("Live", summary)
                            }
                        } else if now - lastStatus >= 1 {
                            lastStatus = now
                            update("Unsupported or invalid video format", "\(frame.width) × \(frame.height) · format 0x\(String(frame.codec, radix: 16))")
                        }
                    } else if mode == .playback, frame.type == 4, let owned = validatedAudio(frame) {
                        lastData = now; hadMedia = true
                        cancellation.admit { audio(owned) }
                        if !receivedVideo && now - lastStatus >= 1 {
                            lastStatus = now
                            update("Live Audio", "\(frame.channels) channels · \(frame.sampleRate) Hz")
                        }
                    }
                }
                if now - lastData > 3 && now - lastStatus >= 1 {
                    lastStatus = now
                    // The official SDK owns reconnect and discovery notifications.
                    // Retaining this instance also follows virtual-source redirects.
                    update(hadMedia ? "Signal lost — reconnecting…" : "Waiting for sender…", nil)
                }
            }
            if previewUnavailable { return }
        }
    }

    /// No unchecked size products: dimensions/stride are bounded first. The
    /// accepted envelope includes UHD/8K, SD, HD and arbitrary rational rates.
    nonisolated static func validatedVideo(_ frame: OMTRFrame, receivedAt: TimeInterval) -> VideoFrame? {
        let width = Int(frame.width), height = Int(frame.height), stride = Int(frame.stride)
        let isPreview = frame.flags & 8 != 0
        let minimumDimension = isPreview ? 2 : 16
        guard (minimumDimension...8192).contains(width), (minimumDimension...8192).contains(height),
              (1...1_000_000).contains(frame.frameRateN), (1...1_000_000).contains(frame.frameRateD),
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
        video: @escaping @Sendable (VideoFrame) -> Void, update: @escaping @Sendable (String, String?) -> Void) {
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
                if index == 0 { update("Test Pattern", frame.summary) }
            }
            index += 1
            let remaining = start + Double(index) / Double(rate) - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { Thread.sleep(forTimeInterval: min(remaining, 1.0 / Double(rate))) }
            else if remaining < -0.100 { index = Int64((ProcessInfo.processInfo.systemUptime - start) * Double(rate)) }
        }
    }
}
