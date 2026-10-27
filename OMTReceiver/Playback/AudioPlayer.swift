import AVFoundation
import Foundation
import os

/// Planar Float32 admission is bounded before dispatch. AVAudioEngine converts
/// only the device sample rate/channel layout; source PCM retains its sample rate.
final class AudioPlayer: @unchecked Sendable {
    /// A notification is a prompt to read current state, never an error payload
    /// that could outlive its source while waiting for the main actor.
    var onStateChange: (@Sendable () -> Void)?
    private let clock: PlaybackClock
    private let lock = NSLock()
    private var healthError: String?
    var errorMessage: String? { lock.lock(); defer { lock.unlock() }; return healthError }
    // This is the graph-control/submission lane, not the real-time render
    // thread (which AVAudioEngine owns). Native graph operations synchronously
    // join framework workers at default QoS, so UI priority is inappropriate.
    // Keep creation, scheduling, reset and retirement serialized on this lane.
    private let queue = DispatchQueue(label: "OMTReceiver.audio.control", qos: .default)
    private let signal: DispatchSourceUserDataAdd
    private var incoming = AudioFrameQueue()
    private var muted = false
    private var resetPending = false
    private var generation: UInt64 = 0
    // Below is owned exclusively by queue.
    private let makeRenderer: @Sendable (Double, Int) throws -> any AudioRendering
    private var renderer: (any AudioRendering)?
    private var renderSampleRate: Double?
    private var renderChannels: Int?
    private var scheduledDuration: Double = 0
    private var renderGeneration: UInt64 = 0
    private var configurationObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.suku.OMTReceiver.macOS", category: "Audio")

    init(clock: PlaybackClock = PlaybackClock(),
         makeRenderer: @escaping @Sendable (Double, Int) throws -> any AudioRendering = {
             try CoreAudioRenderer(sampleRate: $0, channels: $1)
         }) {
        self.clock = clock
        self.makeRenderer = makeRenderer
        signal = DispatchSource.makeUserDataAddSource(queue: queue)
        signal.setEventHandler { [weak self] in self?.drain() }
        signal.resume()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, let changed = notification.object as AnyObject?,
                      changed === self.renderer?.configurationObject else { return }
                self.retireEngine()
            }
        }
    }

    func enqueue(_ frame: AudioFrame) {
        guard let admitted = AudioFrameQueue.normalized(frame) else { return }
        lock.lock()
        let droppedBacklog = incoming.append(admitted.frame)
        resetPending = resetPending || admitted.trimmed || droppedBacklog
        lock.unlock()
        signal.add(data: 1)
    }

    func setMuted(_ value: Bool) {
        lock.lock(); muted = value; lock.unlock()
        signal.add(data: 1)
    }

    /// Clears this epoch without making the main thread wait for Core Audio.
    func stop() {
        lock.lock()
        incoming.removeAll()
        resetPending = true; generation &+= 1
        let healthChanged = healthError != nil
        healthError = nil
        lock.unlock()
        clock.reset()
        signal.add(data: 1)
        if healthChanged { onStateChange?() }
    }

    private func drain() {
        lock.lock()
        let frames = incoming.takeAll()
        let reset = resetPending; resetPending = false
        let isMuted = muted
        let token = generation
        lock.unlock()
        if reset { retireEngine() }
        renderer?.setVolume(isMuted ? 0 : 1)
        for frame in frames {
            lock.lock(); let stillCurrent = generation == token; lock.unlock()
            guard stillCurrent else { return }
            do {
                try prepare(sampleRate: frame.sampleRate, channels: frame.channels)
                guard let renderer else { continue }
                renderer.setVolume(isMuted ? 0 : 1)
                let duration = frame.duration
                if scheduledDuration + duration > AudioFrameQueue.maximumScheduledDuration {
                    renderer.reset(); scheduledDuration = 0; renderGeneration &+= 1
                }
                // Fence the actual Core Audio admission, including the clock
                // mapping, against a source switch during graph preparation.
                lock.lock()
                do {
                    defer { lock.unlock() }
                    guard generation == token else { return }
                    let host = clock.presentationTime(for: frame.timestamp)
                    scheduledDuration += duration
                    let renderToken = renderGeneration
                    try renderer.schedule(frame, hostTime: host) { [weak self] in
                        self?.queue.async { [weak self] in
                            guard let self, self.renderGeneration == renderToken else { return }
                            self.scheduledDuration = max(0, self.scheduledDuration - duration)
                        }
                    }
                }
                publishHealth(nil, generation: token)
            } catch {
                logger.error("Audio playback failed: \(error.localizedDescription, privacy: .public)")
                publishHealth("Audio unavailable: \(error.localizedDescription)", generation: token)
                retireEngine()
                return
            }
        }
    }

    private func publishHealth(_ error: String?, generation token: UInt64) {
        lock.lock()
        guard generation == token else { lock.unlock(); return }
        let changed = healthError != error
        healthError = error
        lock.unlock()
        if changed { onStateChange?() }
    }

    private func prepare(sampleRate: Double, channels: Int) throws {
        if renderSampleRate == sampleRate, renderChannels == channels,
           renderer?.isRunning == true { return }
        retireEngine()
        renderer = try makeRenderer(sampleRate, channels)
        renderSampleRate = sampleRate; renderChannels = channels
    }

    private func retireEngine() {
        renderGeneration &+= 1
        renderer?.stop()
        renderer = nil; renderSampleRate = nil; renderChannels = nil; scheduledDuration = 0
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        signal.cancel()
        // Pending handlers hold only weak self; an executing drain keeps self
        // alive. At final release there can therefore be no concurrent graph
        // operation. Transfer its unique ownership onto the same control lane,
        // including stop and final ARC release, rather than joining Core Audio
        // from whichever thread releases AudioPlayer (possibly the main thread).
        let retirement = renderer.map(AudioRendererRetirement.init)
        renderer = nil
        if let retirement {
            queue.async { retirement.finish() }
        }
    }
}

/// A one-way ownership transfer used only by AudioPlayer's final release. The
/// non-Sendable graph is used and released once, on its original serial lane.
private final class AudioRendererRetirement: @unchecked Sendable {
    private var renderer: (any AudioRendering)?
    init(_ renderer: any AudioRendering) { self.renderer = renderer }
    func finish() { renderer?.stop(); renderer = nil }
}

/// Pure PCM backlog policy. Keep the newest bounded window rather than
/// rejecting valid long chunks or letting one chunk bypass the latency budget.
struct AudioFrameQueue {
    static let maximumIncomingDuration = 0.300
    static let maximumScheduledDuration = 0.350
    private(set) var frames: [AudioFrame] = []
    private(set) var duration: Double = 0

    static func normalized(_ frame: AudioFrame) -> (frame: AudioFrame, trimmed: Bool)? {
        guard frame.sampleRate.isFinite, (8000...384000).contains(frame.sampleRate),
              (1...32).contains(frame.channels), (1...131072).contains(frame.samplesPerChannel),
              frame.data.count >= frame.channels * frame.samplesPerChannel * 4 else { return nil }
        let keptSamples = min(frame.samplesPerChannel, Int(floor(frame.sampleRate * maximumIncomingDuration)))
        guard keptSamples < frame.samplesPerChannel else { return (frame, false) }
        let omittedSamples = frame.samplesPerChannel - keptSamples
        let channelBytes = keptSamples * MemoryLayout<Float>.size
        var data = Data(count: channelBytes * frame.channels)
        data.withUnsafeMutableBytes { target in
            frame.data.withUnsafeBytes { source in
                for channel in 0..<frame.channels {
                    memcpy(target.baseAddress!.advanced(by: channel * channelBytes),
                           source.baseAddress!.advanced(by: (channel * frame.samplesPerChannel + omittedSamples) * MemoryLayout<Float>.size),
                           channelBytes)
                }
            }
        }
        let ticks = Int64((Double(omittedSamples) * 10_000_000 / frame.sampleRate).rounded())
        let (advanced, overflow) = frame.timestamp.addingReportingOverflow(ticks)
        return (AudioFrame(sampleRate: frame.sampleRate, channels: frame.channels,
                           samplesPerChannel: keptSamples, timestamp: overflow ? Int64.max : advanced, data: data), true)
    }

    /// Returns whether old backlog was discarded and scheduled audio must reset.
    mutating func append(_ frame: AudioFrame) -> Bool {
        var dropped = false
        while !frames.isEmpty && (frames.count >= 32 || duration + frame.duration > Self.maximumIncomingDuration) {
            duration -= frames.removeFirst().duration
            dropped = true
        }
        frames.append(frame); duration += frame.duration
        return dropped
    }

    mutating func takeAll() -> [AudioFrame] {
        let result = frames
        removeAll()
        return result
    }
    mutating func removeAll() { frames.removeAll(keepingCapacity: true); duration = 0 }
}

extension AudioFrame {
    var duration: Double { Double(samplesPerChannel) / sampleRate }
}

/// Core Audio stays behind a rendering boundary so scheduling and epoch fences
/// can be verified without depending on a physical audio device.
protocol AudioRendering: AnyObject {
    var isRunning: Bool { get }
    var configurationObject: AnyObject? { get }
    func setVolume(_ value: Float)
    func reset()
    func schedule(_ frame: AudioFrame, hostTime: Double, completion: @escaping @Sendable () -> Void) throws
    func stop()
}

final class CoreAudioRenderer: AudioRendering {
    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    var isRunning: Bool { engine.isRunning }
    var configurationObject: AnyObject? { engine }

    init(sampleRate: Double, channels: Int, engine: AVAudioEngine = AVAudioEngine()) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false) else {
            throw NSError(domain: "OMTReceiver.Audio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported audio format."])
        }
        self.format = format
        self.engine = engine
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        player.play()
    }

    func setVolume(_ value: Float) { player.volume = value }
    func reset() { player.stop(); player.play() }
    func schedule(_ frame: AudioFrame, hostTime: Double, completion: @escaping @Sendable () -> Void) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.samplesPerChannel)),
              let planes = buffer.floatChannelData else {
            throw NSError(domain: "OMTReceiver.Audio", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot allocate an audio buffer."])
        }
        buffer.frameLength = AVAudioFrameCount(frame.samplesPerChannel)
        frame.data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            for channel in 0..<frame.channels {
                memcpy(planes[channel], base.advanced(by: channel * frame.samplesPerChannel * 4), frame.samplesPerChannel * 4)
            }
        }
        let presentation = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: hostTime))
        player.scheduleBuffer(buffer, at: presentation, options: [], completionCallbackType: .dataPlayedBack) { _ in completion() }
    }
    func stop() { player.stop(); engine.stop() }
}
