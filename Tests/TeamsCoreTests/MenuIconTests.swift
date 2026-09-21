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

@Suite("Menu icon geometry + palette")
struct MenuIconGeometryTests {
    func inside(_ x: Double, _ y: Double) -> Bool {
        x >= 0 && x <= MenuIcon.canvasSize && y >= 0 && y <= MenuIcon.canvasSize
    }

    @Test func canvasIsMenuBarSize() {
        #expect(MenuIcon.canvasSize == 18.0)
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

    @Test func teamsPurple() {
        #expect(MenuIcon.purple.r == 0x62)
        #expect(MenuIcon.purple.g == 0x64)
        #expect(MenuIcon.purple.b == 0xA7)
    }
}
