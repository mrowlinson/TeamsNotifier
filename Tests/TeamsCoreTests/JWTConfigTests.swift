import Testing
@testable import TeamsCore

@Suite("JWT + Config")
struct JWTConfigTests {
    // {"oid":"11111111-2222-3333-4444-555555555555","upn":"michael@company.com","name":"Michael Rowlinson","exp":1999999999}
    static let token = "eyJhbGciOiJub25lIn0.eyJvaWQiOiIxMTExMTExMS0yMjIyLTMzMzMtNDQ0NC01NTU1NTU1NTU1NTUiLCJ1cG4iOiJtaWNoYWVsQGNvbXBhbnkuY29tIiwibmFtZSI6Ik1pY2hhZWwgUm93bGluc29uIiwiZXhwIjoxOTk5OTk5OTk5fQ."

    @Test func decodesClaims() throws {
        let c = try JWT.decode(Self.token)
        #expect(c.oid == "11111111-2222-3333-4444-555555555555")
        #expect(c.upn == "michael@company.com")
        #expect(c.name == "Michael Rowlinson")
        #expect(c.exp == 1999999999)
    }

    @Test func malformedThrows() {
        #expect(throws: JWT.Error.self) { try JWT.decode("abc") }
        #expect(throws: JWT.Error.self) { try JWT.decode("a.b.c") }
    }

    @Test func defaults() {
        #expect(Config.default.loudSubstring == "BTAC")
        #expect(Config.default.owner.displayName == "Michael Rowlinson")
        #expect(Config.default.notifyOnEdit == false)
        #expect(Config.default.skipOwnMessages == true)
    }
}
