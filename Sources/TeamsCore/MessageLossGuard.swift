import Foundation

/// Settle guard for trouter.message_loss re-registration.
///
/// The server can emit a burst of message_loss events (seen: 5x right after
/// "registrations done" on first connect — one per queue/worker resyncing,
/// benign). The naive handler re-registers the worker on EVERY event with no
/// settle, so a persistent loss condition becomes an unbounded re-register
/// loop, each await blocking the receive loop. Guard: re-register at most
/// once per settle window; past maxConsecutive losses inside one window,
/// hold (stop re-registering) and let the caller fault.
public struct MessageLossGuard: Sendable {
    /// Losses within this window after a re-register are ignored.
    public let settleWindow: TimeInterval
    /// Losses inside one window past this count -> .hold.
    public let maxConsecutive: Int

    private var lastReregister: Date?
    private var consecutive: Int = 0

    public enum Action: Sendable, Equatable {
        case reregister
        case ignoreSettle
        case hold
    }

    public init(settleWindow: TimeInterval = 60, maxConsecutive: Int = 5) {
        self.settleWindow = settleWindow
        self.maxConsecutive = maxConsecutive
    }

    public mutating func recordLoss(now: Date = Date()) -> Action {
        if let last = lastReregister, now.timeIntervalSince(last) < settleWindow {
            consecutive += 1
            return consecutive > maxConsecutive ? .hold : .ignoreSettle
        }
        lastReregister = now
        consecutive = 1
        return .reregister
    }
}
