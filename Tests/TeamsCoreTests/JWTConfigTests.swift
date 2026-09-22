import Testing
@testable import TeamsCore

@Suite("JWT + Config")
struct JWTConfigTests {
    // {"oid":"11111111-2222-3333-4444-555555555555","upn":"alex@company.com","name":"Alex Rivera","exp":1999999999}
    static let token = "eyJhbGciOiJub25lIn0.eyJvaWQiOiIxMTExMTExMS0yMjIyLTMzMzMtNDQ0NC01NTU1NTU1NTU1NTUiLCJ1cG4iOiJhbGV4QGNvbXBhbnkuY29tIiwibmFtZSI6IkFsZXggUml2ZXJhIiwiZXhwIjoxOTk5OTk5OTk5fQ."

    @Test func decodesClaims() throws {
        let c = try JWT.decode(Self.token)
        #expect(c.oid == "11111111-2222-3333-4444-555555555555")
        #expect(c.upn == "alex@company.com")
        #expect(c.name == "Alex Rivera")
        #expect(c.exp == 1999999999)
    }

    @Test func malformedThrows() {
        #expect(throws: JWT.Error.self) { try JWT.decode("abc") }
        #expect(throws: JWT.Error.self) { try JWT.decode("a.b.c") }
    }

    @Test func defaults() {
        #expect(Config.default.loudSubstring == "")
        #expect(Config.default.owner.displayName == "")
        #expect(Config.default.notifyOnEdit == false)
        #expect(Config.default.skipOwnMessages == true)
    }

    @Test func legacyFillsPinPrePublicBehavior() {
        #expect(Config.Legacy.loudSubstring == "BTAC")
        #expect(Config.Legacy.notifyTypes == ["Text", "RichText"])
        #expect(Config.Legacy.ownerDisplayName.isEmpty == false)
    }
}
