/// Menu-bar icon variant selection + geometry. Pure (no AppKit): the
/// renderer in TeamsNotifier/MenuIconImage.swift draws from these numbers,
/// so selection priority and canvas-fit are unit-testable here.
public enum MenuIcon {
    public enum Variant: String, Sendable, Equatable {
        case plain
        case unread
        case blocked
    }

    /// Priority mirrors the old bell/bell.badge/bell.slash mapping:
    /// blocked (denied or switched off in Settings) wins over unread.
    /// Muted has no icon state by design (plain bubble; mute gates
    /// inbound notifications only, same as before).
    public static func select(notifyOff: Bool, blocked: Bool, hasUnread: Bool) -> Variant {
        if notifyOff || blocked { return .blocked }
        if hasUnread { return .unread }
        return .plain
    }

    // MARK: - Geometry (points, 18pt menu-bar canvas, origin bottom-left)

    public static let canvasSize = 18.0

    /// Rounded-rect chat bubble.
    public static let bubbleX = 1.0
    public static let bubbleY = 3.5
    public static let bubbleW = 16.0
    public static let bubbleH = 12.5
    public static let bubbleRadius = 3.5

    /// Chat tail triangle hanging off the bubble's bottom-left.
    public static let tail: [(x: Double, y: Double)] = [
        (5.5, 4.0), (3.5, 1.0), (8.0, 4.0),
    ]

    /// Unread dot over the bubble's top-right corner (white ring + orange
    /// fill drawn concentric; radius here is the outer ring).
    public static let dotX = 14.9
    public static let dotY = 13.9
    public static let dotRadius = 3.0

    /// Blocked slash across the bubble (bottom-left to top-right).
    public static let slashFrom = (x: 3.0, y: 5.0)
    public static let slashTo = (x: 15.5, y: 15.0)

    // MARK: - Palette (0-255 ints)

    /// Teams purple #6264A7. No fixture purple exists in-repo; classic value.
    public static let purple = (r: 98, g: 100, b: 167)
    /// Blocked bubble: purple desaturated to luminance-matched gray (~0.45).
    public static let blockedGray = 115
    /// Unread dot fill (white ring drawn under it for separation).
    public static let unreadOrange = (r: 255, g: 149, b: 0)
}
