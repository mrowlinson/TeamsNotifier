import Testing
@testable import TeamsCore

@Suite("Registrar response acceptance")
struct RegistrarTests {
    @Test func ok200() {
        #expect(RegistrarResponse.isSuccess(statusCode: 200))
    }

    @Test func created201() {
        #expect(RegistrarResponse.isSuccess(statusCode: 201))
    }

    @Test func accepted202EmptyBody() {
        // Live registrar answers 202 with an empty body; must not retry-loop.
        #expect(RegistrarResponse.isSuccess(statusCode: 202))
    }

    @Test func other2xxAccepted() {
        for code in [203, 204, 206, 207, 299] {
            #expect(RegistrarResponse.isSuccess(statusCode: code), Comment(rawValue: "code \(code)"))
        }
    }

    @Test func non2xxRejected() {
        for code in [-1, 0, 199, 300, 301, 400, 401, 403, 404, 429, 500, 503] {
            #expect(!RegistrarResponse.isSuccess(statusCode: code), Comment(rawValue: "code \(code)"))
        }
    }
}
