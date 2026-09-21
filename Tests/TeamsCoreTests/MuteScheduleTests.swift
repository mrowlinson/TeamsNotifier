import Foundation
import Testing
@testable import TeamsCore

/// Scheduled mute: resolver matrix, boundaries, overrides, transitions.
///
/// Anchor week is 2026-09-21 (Mon) .. 2026-09-27 (Sun); anchorWeekdays pins
/// that assumption so a wrong anchor fails loudly instead of silently
/// shifting every case.
///
/// DST note: the app passes an identifier zone (America/New_York), so DST is
/// automatic and the math reads wall clock via Calendar. Tests inject zones
/// explicitly: ET for spec behavior, a fixed GMT+5 zone to prove the zone is
/// honored (not the machine zone), plus real DST Mondays (Mar 9 / Nov 2 2026).
@Suite("Mute schedule")
struct MuteScheduleTests {
    static let et = TimeZone(identifier: "America/New_York")!
    static let plus5 = TimeZone(secondsFromGMT: 5 * 3600)!
    static let windows = MuteWindow.defaults

    static func at(_ s: String, tz: TimeZone? = nil) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz ?? et
        f.dateFormat = s.count > 16 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    static func muted(_ s: String, tz: TimeZone? = nil, windows: [MuteWindow]? = nil) -> Bool {
        MuteSchedule.scheduledMuted(at: at(s, tz: tz), windows: windows ?? Self.windows, timeZone: tz ?? et)
    }

    static func next(_ s: String, tz: TimeZone? = nil, windows: [MuteWindow]? = nil) -> Date? {
        MuteSchedule.nextTransition(after: at(s, tz: tz), windows: windows ?? Self.windows, timeZone: tz ?? et)
    }

    // MARK: anchors

    @Test func anchorWeekdays() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.et
        #expect(cal.component(.weekday, from: Self.at("2026-09-21 12:00")) == 2) // Mon
        #expect(cal.component(.weekday, from: Self.at("2026-09-25 12:00")) == 6) // Fri
        #expect(cal.component(.weekday, from: Self.at("2026-09-26 12:00")) == 7) // Sat
        #expect(cal.component(.weekday, from: Self.at("2026-09-27 12:00")) == 1) // Sun
    }

    // MARK: resolver matrix

    @Test func weekdayInsideWindowMuted() {
        #expect(Self.muted("2026-09-21 08:00") == true) // Mon
        #expect(Self.muted("2026-09-22 12:00") == true) // Tue
        #expect(Self.muted("2026-09-23 15:00") == true) // Wed
        #expect(Self.muted("2026-09-24 09:30") == true) // Thu
        #expect(Self.muted("2026-09-25 12:00") == true) // Fri
    }

    @Test func weekdayOutsideWindowUnmuted() {
        #expect(Self.muted("2026-09-21 00:00") == false)
        #expect(Self.muted("2026-09-21 07:00") == false)
        #expect(Self.muted("2026-09-21 17:00") == false)
        #expect(Self.muted("2026-09-21 23:59") == false)
        #expect(Self.muted("2026-09-25 17:00") == false)
        #expect(Self.muted("2026-09-25 23:59") == false)
    }

    @Test func exactBoundaries() {
        // Inclusive start, exclusive end.
        #expect(Self.muted("2026-09-21 07:49") == false)
        #expect(Self.muted("2026-09-21 07:50") == true)
        #expect(Self.muted("2026-09-21 16:39") == true)
        #expect(Self.muted("2026-09-21 16:40") == false)
        // Seconds inside the boundary minutes follow the minute rule.
        #expect(Self.muted("2026-09-21 07:49:59") == false)
        #expect(Self.muted("2026-09-21 07:50:00") == true)
        #expect(Self.muted("2026-09-21 16:39:59") == true)
        #expect(Self.muted("2026-09-21 16:40:01") == false)
    }

    @Test func weekendAllDay() {
        #expect(Self.muted("2026-09-26 00:00") == true) // Sat
        #expect(Self.muted("2026-09-26 12:00") == true)
        #expect(Self.muted("2026-09-26 23:59") == true)
        #expect(Self.muted("2026-09-27 00:00") == true) // Sun
        #expect(Self.muted("2026-09-27 12:00") == true)
        #expect(Self.muted("2026-09-27 23:59") == true)
        // Edges: Fri night and Mon midnight are outside the schedule.
        #expect(Self.muted("2026-09-25 23:59") == false)
        #expect(Self.muted("2026-09-28 00:00") == false) // Mon
    }

    @Test func emptyWindowsNeverMuted() {
        #expect(Self.muted("2026-09-21 08:00", windows: []) == false)
        #expect(Self.muted("2026-09-26 12:00", windows: []) == false)
        #expect(Self.next("2026-09-21 08:00", windows: []) == nil)
    }

    @Test func customWindowsRespected() {
        let w = [MuteWindow(days: [4], start: "09:00", end: "10:00")] // Wed only
        #expect(Self.muted("2026-09-23 09:30", windows: w) == true)
        #expect(Self.muted("2026-09-23 08:59", windows: w) == false)
        #expect(Self.muted("2026-09-23 10:00", windows: w) == false)
        #expect(Self.muted("2026-09-21 09:30", windows: w) == false) // Mon
    }

    @Test func injectedTimeZoneHonored() {
        // Same wall clock in a fixed zone follows the same schedule, proving
        // the zone parameter (not the machine zone) drives the resolver.
        #expect(Self.muted("2026-09-21 08:00", tz: Self.plus5) == true)
        #expect(Self.muted("2026-09-21 17:00", tz: Self.plus5) == false)
        #expect(Self.muted("2026-09-26 12:00", tz: Self.plus5) == true)
        #expect(Self.next("2026-09-21 08:00", tz: Self.plus5) == Self.at("2026-09-21 16:40", tz: Self.plus5))
    }

    @Test func dstMondaysBehave() {
        // 2026 DST starts Mar 8 (EDT) and ends Nov 1 (EST); both anchor
        // Mondays keep wall-clock windows under the identifier zone.
        #expect(Self.muted("2026-03-09 08:00") == true)
        #expect(Self.muted("2026-03-09 17:00") == false)
        #expect(Self.muted("2026-11-02 08:00") == true)
        #expect(Self.muted("2026-11-02 17:00") == false)
        #expect(Self.next("2026-03-09 08:00") == Self.at("2026-03-09 16:40"))
        #expect(Self.next("2026-11-02 08:00") == Self.at("2026-11-02 16:40"))
    }

    // MARK: nextTransition

    @Test func nextTransitionMath() {
        #expect(Self.next("2026-09-21 08:00") == Self.at("2026-09-21 16:40")) // Mon in -> end
        #expect(Self.next("2026-09-21 17:00") == Self.at("2026-09-22 07:50")) // Mon out -> Tue start
        #expect(Self.next("2026-09-21 07:00") == Self.at("2026-09-21 07:50")) // Mon early -> start
        #expect(Self.next("2026-09-25 17:00") == Self.at("2026-09-26 00:00")) // Fri eve -> Sat start
        #expect(Self.next("2026-09-26 00:00") == Self.at("2026-09-28 00:00")) // Sat start -> Mon 00:00
        #expect(Self.next("2026-09-27 12:00") == Self.at("2026-09-28 00:00")) // Sun -> Mon 00:00
        #expect(Self.next("2026-09-27 23:59") == Self.at("2026-09-28 00:00")) // Sun eve -> Mon 00:00
        #expect(Self.next("2026-09-28 00:00") == Self.at("2026-09-28 07:50")) // Mon 00:00 -> Mon start
    }

    @Test func nextTransitionAtExactBoundary() {
        // Strictly after: standing on a boundary yields the FOLLOWING one.
        #expect(Self.next("2026-09-21 07:50") == Self.at("2026-09-21 16:40"))
        #expect(Self.next("2026-09-21 16:40") == Self.at("2026-09-22 07:50"))
    }

    @Test func nextTransitionSkipsNonFlippingBoundaries() {
        // Overlapping windows: 09:00/10:00 boundaries don't flip the state.
        let w = [
            MuteWindow(days: [2], start: "08:00", end: "10:00"),
            MuteWindow(days: [2], start: "09:00", end: "11:00"),
        ]
        #expect(Self.next("2026-09-21 08:30", windows: w) == Self.at("2026-09-21 11:00"))
        #expect(Self.next("2026-09-21 07:00", windows: w) == Self.at("2026-09-21 08:00"))
    }

    // MARK: overrides

    @Test func overrideHoldsUntilBoundary() {
        // Manual unmute during a window holds, then the schedule resumes.
        var s = MuteState()
        let setAt = Self.at("2026-09-21 08:00")
        let sched = MuteSchedule.scheduledMuted(at: setAt, windows: Self.windows, timeZone: Self.et)
        #expect(sched == true)
        let boundary = MuteSchedule.nextTransition(after: setAt, windows: Self.windows, timeZone: Self.et)!
        s.setOverride(false, scheduledNow: sched, nextBoundary: boundary)
        #expect(s.effective(scheduled: true) == false)
        // Mid-window refresh: holds.
        let mid = Self.at("2026-09-21 12:00")
        let midSched = MuteSchedule.scheduledMuted(at: mid, windows: Self.windows, timeZone: Self.et)
        #expect(s.refresh(now: mid, scheduledNow: midSched) == false)
        #expect(s.hasOverride == true)
        // At the boundary the schedule flips and the override clears.
        let end = Self.at("2026-09-21 16:40")
        let endSched = MuteSchedule.scheduledMuted(at: end, windows: Self.windows, timeZone: Self.et)
        #expect(s.refresh(now: end, scheduledNow: endSched) == true)
        #expect(s.hasOverride == false)
        #expect(s.effective(scheduled: endSched) == false)
    }

    @Test func overrideMutedHoldsUntilNextWindow() {
        // Manual mute outside a window holds until the next window starts.
        var s = MuteState()
        let setAt = Self.at("2026-09-21 17:00")
        let sched = MuteSchedule.scheduledMuted(at: setAt, windows: Self.windows, timeZone: Self.et)
        #expect(sched == false)
        let boundary = MuteSchedule.nextTransition(after: setAt, windows: Self.windows, timeZone: Self.et)!
        s.setOverride(true, scheduledNow: sched, nextBoundary: boundary)
        let eve = Self.at("2026-09-21 20:00")
        #expect(s.refresh(now: eve, scheduledNow: false) == false)
        #expect(s.effective(scheduled: false) == true)
        let start = Self.at("2026-09-22 07:50")
        #expect(s.refresh(now: start, scheduledNow: true) == true)
        #expect(s.effective(scheduled: true) == true)
    }

    @Test func manualReMuteSetsNewOverride() {
        // Unmuted by hand, then re-muted by hand: the new override governs
        // until the boundary, then the schedule resumes (unmuted).
        var s = MuteState()
        let setAt = Self.at("2026-09-21 08:00")
        let boundary = MuteSchedule.nextTransition(after: setAt, windows: Self.windows, timeZone: Self.et)!
        s.setOverride(false, scheduledNow: true, nextBoundary: boundary)
        s.setOverride(true, scheduledNow: true, nextBoundary: boundary)
        #expect(s.effective(scheduled: true) == true)
        let end = Self.at("2026-09-21 16:40")
        #expect(s.refresh(now: end, scheduledNow: false) == true)
        #expect(s.effective(scheduled: false) == false)
    }

    @Test func overrideExpiresAcrossWholeWindow() {
        // A whole window passing unseen (sleep) still clears the override via
        // the recorded boundary, even though the schedule value matches again.
        var s = MuteState()
        let setAt = Self.at("2026-09-21 08:00")
        let boundary = MuteSchedule.nextTransition(after: setAt, windows: Self.windows, timeZone: Self.et)!
        #expect(boundary == Self.at("2026-09-21 16:40"))
        s.setOverride(false, scheduledNow: true, nextBoundary: boundary)
        let nextWeek = Self.at("2026-09-28 08:00") // Mon again, muted again
        #expect(s.refresh(now: nextWeek, scheduledNow: true) == true)
        #expect(s.hasOverride == false)
    }

    @Test func refreshWithoutOverrideIsNoop() {
        var s = MuteState()
        #expect(s.refresh(now: Self.at("2026-09-21 08:00"), scheduledNow: true) == false)
        #expect(s.effective(scheduled: true) == true)
        #expect(s.effective(scheduled: false) == false)
    }

    // MARK: reason strings

    @Test func reasonStrings() {
        let end = Self.at("2026-09-21 16:40")
        let start = Self.at("2026-09-22 07:50")
        #expect(MuteSchedule.reason(effectiveMuted: true, hasOverride: false, nextTransition: end, timeZone: Self.et)
            == "Muted · schedule")
        #expect(MuteSchedule.reason(effectiveMuted: false, hasOverride: true, nextTransition: end, timeZone: Self.et)
            == "Unmuted · manual until 4:40 PM ET")
        #expect(MuteSchedule.reason(effectiveMuted: true, hasOverride: true, nextTransition: start, timeZone: Self.et)
            == "Muted · manual until 7:50 AM ET")
        #expect(MuteSchedule.reason(effectiveMuted: false, hasOverride: false, nextTransition: start, timeZone: Self.et)
            == "Unmuted · schedule")
        #expect(MuteSchedule.reason(effectiveMuted: true, hasOverride: true, nextTransition: nil, timeZone: Self.et)
            == "Muted · manual")
    }

    @Test func transitionLabel() {
        #expect(MuteSchedule.transitionLabel(Self.at("2026-09-21 16:40"), timeZone: Self.et) == "4:40 PM ET")
        #expect(MuteSchedule.transitionLabel(Self.at("2026-09-22 07:50"), timeZone: Self.et) == "7:50 AM ET")
    }

    // MARK: parsing + validation + config

    @Test func minutesParsing() {
        #expect(MuteWindow.minutes("07:50") == 470)
        #expect(MuteWindow.minutes("7:50") == 470)
        #expect(MuteWindow.minutes("00:00") == 0)
        #expect(MuteWindow.minutes("16:40") == 1000)
        #expect(MuteWindow.minutes("24:00") == 1440)
        #expect(MuteWindow.minutes("24:01") == nil)
        #expect(MuteWindow.minutes("25:00") == nil)
        #expect(MuteWindow.minutes("07:60") == nil)
        #expect(MuteWindow.minutes("0750") == nil)
        #expect(MuteWindow.minutes("abc") == nil)
        #expect(MuteWindow.minutes("") == nil)
    }

    @Test func windowValidation() {
        #expect(MuteWindow(days: [2, 6], start: "07:50", end: "16:40").isValid == true)
        #expect(MuteWindow(days: [1, 7], start: "00:00", end: "24:00").isValid == true)
        #expect(MuteWindow(days: [], start: "07:50", end: "16:40").isValid == false)
        #expect(MuteWindow(days: [0], start: "07:50", end: "16:40").isValid == false)
        #expect(MuteWindow(days: [8], start: "07:50", end: "16:40").isValid == false)
        #expect(MuteWindow(days: [2], start: "xx", end: "16:40").isValid == false)
        #expect(MuteWindow(days: [2], start: "16:40", end: "07:50").isValid == false)
        #expect(MuteWindow(days: [2], start: "09:00", end: "09:00").isValid == false)
    }

    @Test func configDefaultsSchedule() {
        #expect(Config.default.muteWindows == MuteWindow.defaults)
        #expect(Config.default.scheduleTZ == "America/New_York")
    }

    @Test func legacyConfigDecodesScheduleDefaultsQuietly() throws {
        let json = #"{"owner":{"displayName":"N","upn":"","mri":""},"muted":true}"#
        var c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(c.muteWindows == MuteWindow.defaults)
        #expect(c.scheduleTZ == "America/New_York")
        #expect(c.normalizeSchedule().isEmpty)
    }

    @Test func badWindowFallsBackToDefaults() throws {
        let json = #"{"muteWindows":[{"days":[9],"start":"xx","end":"yy"}]}"#
        var c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let w = c.normalizeSchedule()
        #expect(w.count == 1)
        #expect(c.muteWindows == MuteWindow.defaults)
    }

    @Test func wrongTypedWindowsFallBackToDefaults() throws {
        let json = #"{"muteWindows":"everyday"}"#
        var c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(c.muteWindows == MuteWindow.defaults)
        let w = c.normalizeSchedule()
        #expect(w.count == 1)
        #expect(c.normalizeSchedule().isEmpty) // decode issues drain once
    }

    @Test func unknownTZWarns() throws {
        let json = #"{"scheduleTZ":"Mars/Olympus"}"#
        var c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let w = c.normalizeSchedule()
        #expect(w.count == 1)
        #expect(TimeZone(identifier: c.scheduleTZ) == nil) // app falls back to system tz
    }

    @Test func emptyWindowsListIsValid() throws {
        let json = #"{"muteWindows":[]}"#
        var c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(c.muteWindows.isEmpty)
        #expect(c.normalizeSchedule().isEmpty)
    }

    @Test func scheduleRoundTrips() throws {
        var c = Config.default
        c.muteWindows = [MuteWindow(days: [4], start: "09:00", end: "10:00")]
        c.scheduleTZ = "Europe/Paris"
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        #expect(back.muteWindows == c.muteWindows)
        #expect(back.scheduleTZ == "Europe/Paris")
    }
}
