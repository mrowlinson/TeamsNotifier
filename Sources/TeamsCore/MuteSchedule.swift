import Foundation

/// Weekly mute window: mute when the local day-of-week is in `days` and
/// the local time-of-day is in [start, end).
///
/// - `days`: Calendar weekday numbers (Sunday=1 ... Saturday=7).
/// - `start`/`end`: "HH:MM" 24h strings; `end` may be "24:00" to mean
///   midnight at the end of the day.
public struct MuteWindow: Codable, Sendable, Equatable {
    public var days: [Int]
    public var start: String
    public var end: String

    public init(days: [Int], start: String, end: String) {
        self.days = days
        self.start = start
        self.end = end
    }

    /// Default schedule: muted Mon-Fri 00:00-07:50 + 16:40-24:00 and all
    /// day Sat/Sun; unmuted Mon-Fri 07:50-16:40.
    public static var defaults: [MuteWindow] {
        [
            MuteWindow(days: [2, 3, 4, 5, 6], start: "16:40", end: "24:00"),
            MuteWindow(days: [2, 3, 4, 5, 6], start: "00:00", end: "07:50"),
            MuteWindow(days: [1, 7], start: "00:00", end: "24:00"),
        ]
    }

    /// "HH:MM" -> minutes since midnight, or nil when malformed.
    /// "24:00" is valid (1440) so all-day windows end at midnight.
    /// Single-digit hour ("7:50") is accepted; minutes need 2 digits.
    public static func minutes(_ s: String) -> Int? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              (1 ... 2).contains(parts[0].count), parts[1].count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0 ... 24).contains(h), (0 ... 59).contains(m)
        else { return nil }
        if h == 24, m != 0 { return nil }
        return h * 60 + m
    }

    /// Nil when valid, else a human-readable reason (for the fault log).
    public func issue() -> String? {
        if days.isEmpty { return "mute window has no days: \(self)" }
        if days.contains(where: { !(1 ... 7).contains($0) }) {
            return "mute window days must be 1(Sun)-7(Sat): \(self)"
        }
        guard let s = MuteWindow.minutes(start) else {
            return "bad mute window start (want HH:MM): \(self)"
        }
        guard let e = MuteWindow.minutes(end) else {
            return "bad mute window end (want HH:MM or 24:00): \(self)"
        }
        if s >= e { return "mute window start must be before end: \(self)" }
        return nil
    }

    public var isValid: Bool { issue() == nil }
}

/// Pure scheduled-mute resolver. All functions take an explicit time zone
/// so tests inject fixed zones; the app passes America/New_York (identifier,
/// so DST is automatic) and falls back to the system zone + fault log when
/// the configured identifier is unknown.
public enum MuteSchedule {
    public static let defaultTimeZoneID = "America/New_York"

    /// True when `date` falls inside any window. Boundaries: inclusive
    /// start, exclusive end (16:40 is muted, 07:50 is not).
    public static func scheduledMuted(
        at date: Date, windows: [MuteWindow], timeZone: TimeZone
    ) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let weekday = cal.component(.weekday, from: date)
        let comps = cal.dateComponents([.hour, .minute], from: date)
        let mins = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        for w in windows {
            guard w.days.contains(weekday),
                  let s = MuteWindow.minutes(w.start),
                  let e = MuteWindow.minutes(w.end)
            else { continue }
            if s <= mins, mins < e { return true }
        }
        return false
    }

    /// Next instant after `date` where scheduledMuted flips, or nil when the
    /// schedule never transitions (e.g. no windows). Pure: the app schedules
    /// a Timer on this and re-resolves at fire time.
    public static func nextTransition(
        after date: Date, windows: [MuteWindow], timeZone: TimeZone
    ) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let dayStart = cal.startOfDay(for: date)
        var candidates: [Date] = []
        // 9 days covers a full weekly cycle from any start day (8 would do;
        // the extra day absorbs DST short/long days).
        for offset in 0 ..< 9 {
            guard let day = cal.date(byAdding: .day, value: offset, to: dayStart) else { continue }
            let weekday = cal.component(.weekday, from: day)
            for w in windows where w.days.contains(weekday) {
                guard let s = MuteWindow.minutes(w.start),
                      let e = MuteWindow.minutes(w.end),
                      s < e
                else { continue }
                // Wall-clock construction (not midnight + minutes: DST days
                // are not 1440 minutes long).
                var sc = cal.dateComponents([.year, .month, .day], from: day)
                sc.hour = s / 60
                sc.minute = s % 60
                if let t = cal.date(from: sc) { candidates.append(t) }
                // End is exclusive; 24:00 lands on the next midnight.
                if e == 1440 {
                    if let t = cal.date(byAdding: .day, value: 1, to: day) {
                        candidates.append(cal.startOfDay(for: t))
                    }
                } else {
                    var ec = cal.dateComponents([.year, .month, .day], from: day)
                    ec.hour = e / 60
                    ec.minute = e % 60
                    if let t = cal.date(from: ec) { candidates.append(t) }
                }
            }
        }
        let before = scheduledMuted(at: date, windows: windows, timeZone: timeZone)
        // The schedule only changes at boundaries, so the first boundary
        // after now whose state differs from now is the next transition.
        // (Overlapping windows can share boundaries without flipping; the
        // state check skips those.)
        return candidates
            .filter { $0 > date }
            .sorted()
            .first { scheduledMuted(at: $0, windows: windows, timeZone: timeZone) != before }
    }

    /// "4:40 PM ET" in the schedule zone (fixed ET suffix, DST-agnostic).
    public static func transitionLabel(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "h:mm a"
        return f.string(from: date) + " ET"
    }

    /// Menu status segment: mute state + reason. The manual cases carry the
    /// next-transition time (override holds until then).
    public static func reason(
        effectiveMuted: Bool, hasOverride: Bool,
        nextTransition: Date?, timeZone: TimeZone
    ) -> String {
        if effectiveMuted {
            if hasOverride, let next = nextTransition {
                return "Muted · manual until \(transitionLabel(next, timeZone: timeZone))"
            }
            if hasOverride { return "Muted · manual" }
            return "Muted · schedule"
        }
        if hasOverride, let next = nextTransition {
            return "Unmuted · manual until \(transitionLabel(next, timeZone: timeZone))"
        }
        if hasOverride { return "Unmuted · manual" }
        return "Unmuted · schedule"
    }
}

/// Manual override (memory only: a fresh launch is governed by the
/// schedule). Set on every manual toggle; cleared when a schedule boundary
/// is crossed in either direction, then the schedule resumes.
public struct MuteState: Sendable {
    /// Manual value, or nil when the schedule governs.
    public var override: Bool?
    /// Schedule value when the override was set (crossing detector).
    public var setScheduled = false
    /// Next boundary when the override was set (multi-crossing detector:
    /// e.g. a whole window passing during sleep).
    public var expiresAt: Date?

    public init(override: Bool? = nil) {
        self.override = override
    }

    public var hasOverride: Bool { override != nil }

    public func effective(scheduled: Bool) -> Bool {
        override ?? scheduled
    }

    public mutating func setOverride(_ value: Bool, scheduledNow: Bool, nextBoundary: Date?) {
        override = value
        setScheduled = scheduledNow
        expiresAt = nextBoundary
    }

    public mutating func clearOverride() {
        override = nil
        expiresAt = nil
    }

    /// Drop the override if a boundary was crossed since it was set.
    /// Returns true when the override was cleared.
    @discardableResult
    public mutating func refresh(now: Date, scheduledNow: Bool) -> Bool {
        guard override != nil else { return false }
        if scheduledNow != setScheduled {
            clearOverride()
            return true
        }
        if let exp = expiresAt, now >= exp {
            clearOverride()
            return true
        }
        return false
    }
}
