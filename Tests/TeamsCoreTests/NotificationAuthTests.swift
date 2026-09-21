import Testing
@testable import TeamsCore

@Suite("Notification auth mapping")
struct NotificationAuthTests {
    @Test func onlyDeniedIsBlocked() {
        #expect(!NotificationAuth.isBlocked(rawValue: 0)) // notDetermined
        #expect(NotificationAuth.isBlocked(rawValue: 1)) // denied
        #expect(!NotificationAuth.isBlocked(rawValue: 2)) // authorized
        #expect(!NotificationAuth.isBlocked(rawValue: 3)) // provisional
        #expect(!NotificationAuth.isBlocked(rawValue: 4)) // ephemeral
        #expect(!NotificationAuth.isBlocked(rawValue: 99)) // unknown: not blocked, log label covers it
    }

    @Test func labels() {
        #expect(NotificationAuth.label(rawValue: 0) == "not determined")
        #expect(NotificationAuth.label(rawValue: 1) == "denied")
        #expect(NotificationAuth.label(rawValue: 2) == "authorized")
        #expect(NotificationAuth.label(rawValue: 3) == "provisional")
        #expect(NotificationAuth.label(rawValue: 4) == "ephemeral")
        #expect(NotificationAuth.label(rawValue: 99) == "unknown (99)")
    }
}
