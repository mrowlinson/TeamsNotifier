/// Notification authorization mapping over UNAuthorizationStatus raw values
/// (0 notDetermined, 1 denied, 2 authorized, 3 provisional, 4 ephemeral).
/// Raw Int keeps TeamsCore free of UserNotifications; Notifier passes
/// `status.rawValue` through.
public enum NotificationAuth {
    /// True only for denied: the state that needs a Settings detour.
    /// notDetermined is not blocked (requestAuthorization still pending).
    public static func isBlocked(rawValue: Int) -> Bool {
        rawValue == 1
    }

    public static func label(rawValue: Int) -> String {
        switch rawValue {
        case 0: return "not determined"
        case 1: return "denied"
        case 2: return "authorized"
        case 3: return "provisional"
        case 4: return "ephemeral"
        default: return "unknown (\(rawValue))"
        }
    }
}
