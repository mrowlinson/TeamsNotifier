import Testing
@testable import TeamsCore

@Suite("Menu icon variant selection")
struct MenuIconSelectTests {
    @Test func plainByDefault() {
        #expect(MenuIcon.select(notifyOff: false, blocked: false, hasUnread: false) == .plain)
    }

    @Test func unreadShowsDot() {
        #expect(MenuIcon.select(notifyOff: false, blocked: false, hasUnread: true) == .unread)
    }

    @Test func deniedBlocks() {
        #expect(MenuIcon.select(notifyOff: false, blocked: true, hasUnread: false) == .blocked)
    }

    @Test func settingsOffBlocks() {
        #expect(MenuIcon.select(notifyOff: true, blocked: false, hasUnread: false) == .blocked)
    }

    @Test func blockedWinsOverUnread() {
        #expect(MenuIcon.select(notifyOff: false, blocked: true, hasUnread: true) == .blocked)
        #expect(MenuIcon.select(notifyOff: true, blocked: false, hasUnread: true) == .blocked)
    }
}

@Suite("Menu icon geometry (22pt template)")
struct MenuIconGeometryTests {
    func inside(_ x: Double, _ y: Double) -> Bool {
        x >= 0 && x <= MenuIcon.canvasSize && y >= 0 && y <= MenuIcon.canvasSize
    }

    @Test func canvasIsMenuBarSize() {
        #expect(MenuIcon.canvasSize == 22.0)
    }

    @Test func bubbleInsideCanvas() {
        #expect(inside(MenuIcon.bubbleX, MenuIcon.bubbleY))
        #expect(inside(MenuIcon.bubbleX + MenuIcon.bubbleW, MenuIcon.bubbleY + MenuIcon.bubbleH))
    }

    @Test func tailInsideCanvas() {
        for p in MenuIcon.tail {
            #expect(inside(p.x, p.y))
        }
    }

    @Test func dotCircleInsideCanvas() {
        #expect(inside(MenuIcon.dotX - MenuIcon.dotRadius, MenuIcon.dotY - MenuIcon.dotRadius))
        #expect(inside(MenuIcon.dotX + MenuIcon.dotRadius, MenuIcon.dotY + MenuIcon.dotRadius))
    }

    @Test func slashInsideCanvas() {
        #expect(inside(MenuIcon.slashFrom.x, MenuIcon.slashFrom.y))
        #expect(inside(MenuIcon.slashTo.x, MenuIcon.slashTo.y))
    }

    @Test func plainArtVerticallyCentered() {
        // Symmetric top/bottom padding: tail tip pad == bubble-top pad.
        let bottomPad = MenuIcon.tail.map(\.y).min()!
        let topPad = MenuIcon.canvasSize - (MenuIcon.bubbleY + MenuIcon.bubbleH)
        #expect(abs(topPad - bottomPad) < 0.02)
    }

    @Test func bubbleHorizontallyCentered() {
        let leftPad = MenuIcon.bubbleX
        let rightPad = MenuIcon.canvasSize - (MenuIcon.bubbleX + MenuIcon.bubbleW)
        #expect(abs(leftPad - rightPad) < 0.02)
    }

    @Test func dotRingLeavesFilledDot() {
        #expect(MenuIcon.dotRing > 0)
        #expect(MenuIcon.dotRadius - MenuIcon.dotRing > 0)
    }

    @Test func slashWidthPositive() {
        #expect(MenuIcon.slashWidth > 0)
    }

    @Test func tFontScaledFromV1() {
        // v1 10pt at 18pt canvas -> 10 * 22/18.
        #expect(abs(MenuIcon.tFontSize - 10 * 22 / 18) < 0.05)
    }
}
