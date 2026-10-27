import AVFoundation
import Foundation
import os

/// Planar Float32 admission is bounded before dispatch. AVAudioEngine converts
/// only the device sample rate/channel layout; source PCM retains its sample rate.
final class AudioPlayer: @unchecked Sendable {
    var onError: (@Sendable (String) -> Void)?
    private let clock: PlaybackClock
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "OMTReceiver.audio", qos: .userInteractive)
    private let signal: DispatchSourceUserDataAdd
    private var incoming: [AudioFrame] = []
    private var incomingDuration: Double = 0
    private var muted = false
    private var resetPending = false
    private var generation: UInt64 = 0
    // Below is owned exclusively by queue.
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var scheduledDuration: Double = 0
    private var renderGeneration: UInt64 = 0
    private var configurationObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.suku.OMTReceiver.macOS", category: "Audio")

    init(clock: PlaybackClock = PlaybackClock()) {
        self.clock = clock
        signal = DispatchSource.makeUserDataAddSource(queue: queue)
        signal.setEventHandler { [weak self] in self?.drain() }
        signal.resume()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, let changed = notification.object as? AVAudioEngine,
                      changed === self.engine else { return }
                self.retireEngine()
            }
        }
    }

    func enqueue(_ frame: AudioFrame) {
        guard frame.sampleRate.isFinite, (8000...384000).contains(frame.sampleRate),
              (1...32).contains(frame.channels), (1...131072).contains(frame.samplesPerChannel),
              frame.data.count >= frame.channels * frame.samplesPerChannel * 4 else { return }
        let duration = Double(frame.samplesPerChannel) / frame.sampleRate
        lock.lock()
        if incoming.count >= 32 || incomingDuration + duration > 0.300 {
            incoming.removeAll(keepingCapacity: true); incomingDuration = 0
            resetPending = true
        }
        incoming.append(frame); incomingDuration += duration
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
        incoming.removeAll(keepingCapacity: false); incomingDuration = 0
        resetPending = true; generation &+= 1
        lock.unlock()
        clock.reset()
        signal.add(data: 1)
    }

    private func drain() {
        lock.lock()
        let frames = incoming; incoming.removeAll(keepingCapacity: true)
        incomingDuration = 0
        let reset = resetPending; resetPending = false
        let isMuted = muted
        let token = generation
        lock.unlock()
        if reset { retireEngine() }
        player?.volume = isMuted ? 0 : 1
        for frame in frames {
            lock.lock(); let stillCurrent = generation == token; lock.unlock()
            guard stillCurrent else { return }
            do {
                try prepare(sampleRate: frame.sampleRate, channels: frame.channels)
                guard let player, let format,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format,
                          frameCapacity: AVAudioFrameCount(frame.samplesPerChannel)),
                      let planes = buffer.floatChannelData else { continue }
                player.volume = isMuted ? 0 : 1
                buffer.frameLength = AVAudioFrameCount(frame.samplesPerChannel)
                frame.data.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    for channel in 0..<frame.channels {
                        memcpy(planes[channel], base.advanced(by: channel * frame.samplesPerChannel * 4),
                               frame.samplesPerChannel * 4)
                    }
                }
                let duration = Double(frame.samplesPerChannel) / frame.sampleRate
                if scheduledDuration + duration > 0.350 {
                    player.stop(); scheduledDuration = 0; renderGeneration &+= 1
                    player.play()
                }
                // Fence the actual Core Audio admission, including the clock
                // mapping, against a source switch during graph preparation.
                lock.lock()
                guard generation == token else { lock.unlock(); return }
                let host = clock.presentationTime(for: frame.timestamp)
                let presentation = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: host))
                scheduledDuration += duration
                let renderToken = renderGeneration
                player.scheduleBuffer(buffer, at: presentation,
                    options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    self?.queue.async { [weak self] in
                        guard let self, self.renderGeneration == renderToken else { return }
                        self.scheduledDuration = max(0, self.scheduledDuration - duration)
                    }
                }
                lock.unlock()
            } catch {
                logger.error("Audio playback failed: \(error.localizedDescription, privacy: .public)")
                onError?("Audio unavailable: \(error.localizedDescription)")
                retireEngine()
                return
            }
        }
    }

    private func prepare(sampleRate: Double, channels: Int) throws {
        if format?.sampleRate == sampleRate, format?.channelCount == AVAudioChannelCount(channels),
           engine?.isRunning == true { return }
        retireEngine()
        guard let requested = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false) else {
            throw NSError(domain: "OMTReceiver.Audio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported audio format."])
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: requested)
        engine.prepare()
        try engine.start()
        self.engine = engine; self.player = player; self.format = requested
        player.play()
    }

    private func retireEngine() {
        renderGeneration &+= 1
        player?.stop(); engine?.stop()
        player = nil; engine = nil; format = nil; scheduledDuration = 0
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        signal.cancel()
        // No queued closure retains self; queue-owned graph cannot be used after
        // the final reference is released.
        player?.stop(); engine?.stop()
    }
}
