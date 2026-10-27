import Foundation

/// Track health follows each media channel independently. Connection recovery
/// requires complete media loss; continuing audio or video remains usable.
struct ReceiverMediaHealth {
    enum State: Equatable, Sendable { case waiting, live, stalled, unsupported }
    struct Snapshot: Equatable, Sendable {
        let status: String
        let format: String?
        let videoState: State
        let connectionState: State
    }
    static let signalTimeout: TimeInterval = 3
    private let startedAt: TimeInterval
    private var lastVideo: TimeInterval?
    private var lastAudio: TimeInterval?
    private var videoFormat: String?
    private var videoTimeout = Self.signalTimeout
    private var audioFormat: String?
    private var invalidVideo: (time: TimeInterval, format: String)?

    init(startedAt: TimeInterval) { self.startedAt = startedAt }

    mutating func receivedVideo(format: String, at time: TimeInterval, timeout: TimeInterval = Self.signalTimeout) {
        lastVideo = time; videoFormat = format; invalidVideo = nil
        videoTimeout = max(Self.signalTimeout, timeout)
    }
    mutating func receivedAudio(format: String, at time: TimeInterval) {
        lastAudio = time; audioFormat = format
    }
    mutating func rejectedVideo(format: String, at time: TimeInterval) {
        invalidVideo = (time, format)
    }
    func snapshot(at time: TimeInterval) -> Snapshot? {
        func fresh(_ last: TimeInterval?, timeout: TimeInterval = Self.signalTimeout) -> Bool {
            last.map { time - $0 <= timeout } ?? false
        }
        let videoLive = fresh(lastVideo, timeout: videoTimeout), audioLive = fresh(lastAudio)
        if let invalidVideo, fresh(invalidVideo.time) {
            return Snapshot(status: "Unsupported or invalid video format", format: invalidVideo.format,
                            videoState: .unsupported, connectionState: videoLive || audioLive ? .live : .unsupported)
        }
        if videoLive {
            return Snapshot(status: lastAudio != nil && !audioLive ? "Audio lost — video live" : "Live",
                            format: videoFormat, videoState: .live, connectionState: .live)
        }
        if lastVideo != nil || invalidVideo != nil {
            return Snapshot(status: audioLive ? "Video lost — audio live" : "Signal lost — reconnecting…",
                            format: videoFormat ?? invalidVideo?.format, videoState: .stalled,
                            connectionState: audioLive ? .live : .stalled)
        }
        if audioLive {
            return Snapshot(status: "Live Audio", format: audioFormat, videoState: .waiting, connectionState: .live)
        }
        if lastAudio != nil {
            return Snapshot(status: "Signal lost — reconnecting…", format: audioFormat, videoState: .waiting, connectionState: .stalled)
        }
        if time - startedAt >= Self.signalTimeout {
            return Snapshot(status: "Waiting for sender…", format: nil, videoState: .stalled, connectionState: .stalled)
        }
        return nil
    }
}
