import AppKit
import TeamsCore

/// Code-drawn menu-bar icon: Teams-purple chat bubble with a white bold "T".
/// No PNG assets, no catalog. Vector-drawn in an 18pt NSImage via lockFocus,
/// so backing scales to retina automatically. `isTemplate` stays false: the
/// purple fill is the identifier (template mode would flatten it to black).
enum MenuIconImage {
    /// Nil only when lockFocus yields no graphics context (near-impossible;
    /// caller falls back to "TN" text).
    static func image(for variant: MenuIcon.Variant) -> NSImage? {
        let s = CGFloat(MenuIcon.canvasSize)
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        defer { img.unlockFocus() }
        guard NSGraphicsContext.current != nil else { return nil }
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(variant)
        img.isTemplate = false
        return img
    }

    private static func draw(_ variant: MenuIcon.Variant) {
        let blocked = variant == .blocked
        // Bubble + tail as one filled path.
        let bubble = NSBezierPath(
            roundedRect: NSRect(
                x: MenuIcon.bubbleX, y: MenuIcon.bubbleY,
                width: MenuIcon.bubbleW, height: MenuIcon.bubbleH),
            xRadius: CGFloat(MenuIcon.bubbleRadius),
            yRadius: CGFloat(MenuIcon.bubbleRadius))
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: MenuIcon.tail[0].x, y: MenuIcon.tail[0].y))
        tail.line(to: NSPoint(x: MenuIcon.tail[1].x, y: MenuIcon.tail[1].y))
        tail.line(to: NSPoint(x: MenuIcon.tail[2].x, y: MenuIcon.tail[2].y))
        tail.close()
        bubble.append(tail)
        if blocked {
            gray(MenuIcon.blockedGray).setFill()
        } else {
            let p = MenuIcon.purple
            rgb(p.r, p.g, p.b).setFill()
        }
        bubble.fill()

        // White bold "T" centered in the bubble body (above the tail).
        let body = NSRect(
            x: MenuIcon.bubbleX, y: MenuIcon.bubbleY,
            width: MenuIcon.bubbleW, height: MenuIcon.bubbleH)
        let font = NSFont.boldSystemFont(ofSize: 10)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let tAlpha: CGFloat = blocked ? 0.55 : 1.0
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(tAlpha),
            .paragraphStyle: style,
        ]
        let tSize = ("T" as NSString).size(withAttributes: attrs)
        let tRect = NSRect(
            x: body.minX,
            y: body.minY + (body.height - tSize.height) / 2 + 0.5,
            width: body.width, height: tSize.height)
        ("T" as NSString).draw(in: tRect, withAttributes: attrs)

        switch variant {
        case .plain:
            break
        case .unread:
            // White ring + orange fill, concentric over bubble corner.
            let c = NSPoint(x: MenuIcon.dotX, y: MenuIcon.dotY)
            circle(at: c, radius: CGFloat(MenuIcon.dotRadius), color: .white)
            let o = MenuIcon.unreadOrange
            circle(at: c, radius: CGFloat(MenuIcon.dotRadius) - 0.9, color: rgb(o.r, o.g, o.b))
        case .blocked:
            // Outlined slash: dark underlay + white core reads on both
            // light and dark menu bars.
            let path = NSBezierPath()
            path.move(to: NSPoint(x: MenuIcon.slashFrom.x, y: MenuIcon.slashFrom.y))
            path.line(to: NSPoint(x: MenuIcon.slashTo.x, y: MenuIcon.slashTo.y))
            path.lineCapStyle = .round
            NSColor.black.withAlphaComponent(0.75).setStroke()
            path.lineWidth = 3.2
            path.stroke()
            NSColor.white.setStroke()
            path.lineWidth = 1.8
            path.stroke()
        }
    }

    private static func circle(at c: NSPoint, radius r: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(calibratedRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    private static func gray(_ v: Int) -> NSColor {
        NSColor(calibratedWhite: CGFloat(v) / 255, alpha: 1)
    }
}
