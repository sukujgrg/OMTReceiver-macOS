import Foundation

/// Evaluated by existing receiver health updates, without another timer.
/// Live media resets the delay; failed connection attempts retain it.
struct ReceiverReconnectBackoff {
    private var nextDelay: TimeInterval = 1
    private var retryAt: TimeInterval?

    mutating func shouldReconnect(state: ReceiverMediaHealth.State, at time: TimeInterval) -> Bool {
        switch state {
        case .live:
            reset()
        case .waiting, .unsupported:
            retryAt = nil
        case .stalled:
            guard let retryAt else {
                self.retryAt = time + nextDelay
                return false
            }
            if time >= retryAt {
                self.retryAt = nil
                nextDelay = min(30, nextDelay * 2)
                return true
            }
        }
        return false
    }

    mutating func reset() { nextDelay = 1; retryAt = nil }
}
