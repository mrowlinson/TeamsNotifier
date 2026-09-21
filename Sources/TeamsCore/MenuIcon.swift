/// Menu-bar icon variant selection + geometry. Pure (no AppKit): the
/// renderer in TeamsNotifier/MenuIconImage.swift draws from these numbers,
/// so selection priority and canvas-fit are unit-testable here.
///
/// Template art: shapes only, no color. The renderer draws opaque black
/// and macOS tints for light/dark menu bars; the "T", unread ring, and
/// blocked slash are knocked out (transparent), never white paint.
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

    // MARK: - Geometry (points, 22pt menu-bar canvas, origin bottom-left)

    /// v1 was an 18pt canvas; every value below is the v1 number scaled
    /// by 22/18, then shifted +11/18pt in Y so the plain art (bubble +
    /// tail) sits vertically centered: top and bottom pads are equal.
    public static let canvasSize = 22.0

    /// Rounded-rect chat bubble.
    public static let bubbleX = 1.22
    public static let bubbleY = 4.89
    public static let bubbleW = 19.56
    public static let bubbleH = 15.28
    public static let bubbleRadius = 4.28

    /// Bold "T" knocked out of the bubble body (point size).
    public static let tFontSize = 12.2

    /// Chat tail triangle hanging off the bubble's bottom-left.
    public static let tail: [(x: Double, y: Double)] = [
        (6.72, 5.5), (4.28, 1.83), (9.78, 5.5),
    ]

    /// Unread dot over the bubble's top-right corner: outer radius is the
    /// knockout (clear ring separating dot from bubble); the filled dot
    /// radius is dotRadius - dotRing.
    public static let dotX = 18.21
    public static let dotY = 17.6
    public static let dotRadius = 3.67
    public static let dotRing = 1.1

    /// Blocked slash across the bubble (bottom-left to top-right),
    /// knocked out of the bubble fill.
    public static let slashFrom = (x: 3.67, y: 6.72)
    public static let slashTo = (x: 18.94, y: 18.94)
    public static let slashWidth = 2.2
}
