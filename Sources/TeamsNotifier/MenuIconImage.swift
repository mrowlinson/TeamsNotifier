import AppKit
import TeamsCore

/// Code-drawn menu-bar icon: monochrome chat bubble with a knocked-out
/// bold "T". No PNG assets, no catalog. Vector-drawn in a 22pt NSImage via
/// lockFocus, so backing scales to retina automatically. `isTemplate` is
/// true and all art is opaque black: macOS tints for light/dark menu bars.
/// Cutouts (T, unread ring, blocked slash) erase to transparent via
/// destinationOut, so they read on any tint or wallpaper.
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
        img.isTemplate = true
        return img
    }

    private static func draw(_ variant: MenuIcon.Variant) {
        // Bubble + tail as one filled black path.
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
        NSColor.black.setFill()
        bubble.fill()

        // Bold "T" knocked out of the bubble body (above the tail).
        let body = NSRect(
            x: MenuIcon.bubbleX, y: MenuIcon.bubbleY,
            width: MenuIcon.bubbleW, height: MenuIcon.bubbleH)
        let font = NSFont.boldSystemFont(ofSize: CGFloat(MenuIcon.tFontSize))
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: style,
        ]
        let tSize = ("T" as NSString).size(withAttributes: attrs)
        let tRect = NSRect(
            x: body.minX,
            y: body.minY + (body.height - tSize.height) / 2 + 0.6,
            width: body.width, height: tSize.height)
        knockout {
            ("T" as NSString).draw(in: tRect, withAttributes: attrs)
        }

        switch variant {
        case .plain:
            break
        case .unread:
            // Clear ring then filled dot, concentric over bubble corner.
            let c = NSPoint(x: MenuIcon.dotX, y: MenuIcon.dotY)
            knockout {
                fillCircle(at: c, radius: CGFloat(MenuIcon.dotRadius), color: .black)
            }
            fillCircle(
                at: c,
                radius: CGFloat(MenuIcon.dotRadius - MenuIcon.dotRing),
                color: .black)
        case .blocked:
            // Slash cut through the bubble; transparent gap reads on both
            // light and dark menu bars.
            let path = NSBezierPath()
            path.move(to: NSPoint(x: MenuIcon.slashFrom.x, y: MenuIcon.slashFrom.y))
            path.line(to: NSPoint(x: MenuIcon.slashTo.x, y: MenuIcon.slashTo.y))
            path.lineCapStyle = .round
            knockout {
                NSColor.black.setStroke()
                path.lineWidth = CGFloat(MenuIcon.slashWidth)
                path.stroke()
            }
        }
    }

    /// Runs `work` with the context erasing to transparent instead of
    /// painting (restores sourceOver after). Paint color inside is
    /// irrelevant; only alpha matters.
    private static func knockout(_ work: () -> Void) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setBlendMode(.destinationOut)
        work()
        ctx.setBlendMode(.normal)
    }

    private static func fillCircle(at c: NSPoint, radius r: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
    }
}
