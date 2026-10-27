import AVFoundation
import Foundation
import QuartzCore

/// One shared sender-to-host mapping per view. No frame-rate conversion or
/// wall-clock dependency: OMT timestamps are rational 100 ns ticks.
final class PlaybackClock: @unchecked Sendable {
    private let lock = NSLock()
    private var sourceAnchor: Int64?
    private var hostAnchor: Double = 0
    let latency: Double

    init(latency: Double = 0.060) { self.latency = latency }

    func presentationTime(for timestamp: Int64) -> Double {
        lock.lock(); defer { lock.unlock() }
        let now = CACurrentMediaTime()
        guard let anchor = sourceAnchor else {
            sourceAnchor = timestamp; hostAnchor = now + latency
            return hostAnchor
        }
        let mapped = hostAnchor + (Double(timestamp) - Double(anchor)) / 10_000_000
        // A restart or long interruption establishes a fresh local epoch.
        if !mapped.isFinite || mapped < now - 0.250 || mapped > now + 1.0 {
            sourceAnchor = timestamp; hostAnchor = now + latency
            return hostAnchor
        }
        return mapped
    }

    func reset() {
        lock.lock(); sourceAnchor = nil; lock.unlock()
    }
}
