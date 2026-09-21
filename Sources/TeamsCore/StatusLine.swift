/// Menu status line + diagnostics text builders. Pure, tested.
public enum StatusLine {
    /// Short notify label for the status line. Differs from
    /// NotificationAuth.label only for notDetermined -> "undetermined".
    public static func shortNotifyLabel(rawValue: Int) -> String {
        switch rawValue {
        case 0: return "undetermined"
        case 1: return "denied"
        case 2: return "authorized"
        case 3: return "provisional"
        case 4: return "ephemeral"
        default: return "unknown (\(rawValue))"
        }
    }

    /// "connected" + authorized -> "connected · notify authorized".
    /// nil auth (never fetched) leaves the base untouched.
    public static func build(base: String, notifyRawValue: Int?) -> String {
        guard let raw = notifyRawValue else { return base }
        return "\(base) · notify \(shortNotifyLabel(rawValue: raw))"
    }

    /// Clipboard body for "Copy diagnostics".
    public static func diagnostics(authLabel: String, trouterState: String, lastLines: [String]) -> String {
        var out = "TeamsNotifier diagnostics\n"
        out += "notify: \(authLabel)\n"
        out += "trouter: \(trouterState)\n"
        out += "--- last \(lastLines.count) log lines ---\n"
        out += lastLines.joined(separator: "\n")
        return out
    }
}
