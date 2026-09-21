import Foundation

/// Proactive token refresh schedule. Pure math; AuthManager runs the loop.
///
/// Goal: rolling refresh keeps the session alive indefinitely instead of
/// dying at AAD expiry and forcing interactive sign-in.
public enum KeepAlive {
    /// Floor: never schedule tighter than 60s (tight-loop guard).
    public static let minDelay: TimeInterval = 60
    /// Cap: refresh at least every 30m even for long-lived tokens.
    public static let maxDelay: TimeInterval = 30 * 60

    /// Delay until next proactive refresh given the token lifetime
    /// (expires_in seconds): half the lifetime, clamped to [60s, 30m].
    /// 3600s token -> 1800s; 24h token -> 1800s; 100s token -> 60s.
    public static func refreshDelay(expiresIn: TimeInterval) -> TimeInterval {
        min(max(expiresIn * 0.5, minDelay), maxDelay)
    }

    /// Backoff between retries after failed refreshes (failures >= 1):
    /// 60s, 120s, 240s, 480s, then 600s capped.
    public static func retryDelay(failures: Int) -> TimeInterval {
        let shift = min(max(failures - 1, 0), 4)
        return min(minDelay * TimeInterval(1 << shift), 10 * 60)
    }
}
