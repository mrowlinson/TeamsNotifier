/// Per-setting notification state. authorizationStatus can report
/// authorized while the owner has the app switched OFF in Settings >
/// Notifications (or style None) — in that case banners never appear and the
/// menu must say so. Pure mapping over raw enum values so TeamsCore stays
/// free of UserNotifications imports:
///
/// - alertSettingRaw: UNNotificationSetting (notSupported=0, disabled=1, enabled=2)
/// - alertStyleRaw: UNAlertStyle (none=0, banner=1, alert=2)
public enum NotifySettings {
    public static let offSuffix = " · notifications off in Settings"

    /// True when banners cannot appear: alert delivery disabled or style None.
    public static func isAlertOff(alertSettingRaw: Int, alertStyleRaw: Int) -> Bool {
        alertSettingRaw == 1 || alertStyleRaw == 0
    }

    /// Menu status suffix when alerts are off, else nil.
    public static func statusSuffix(alertSettingRaw: Int, alertStyleRaw: Int) -> String? {
        isAlertOff(alertSettingRaw: alertSettingRaw, alertStyleRaw: alertStyleRaw) ? offSuffix : nil
    }
}
