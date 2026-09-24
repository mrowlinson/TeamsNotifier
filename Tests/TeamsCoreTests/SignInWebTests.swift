import Foundation
import Testing
@testable import TeamsCore

/// In-app sign-in pure logic: start-URL choice, failure copy, notification
/// identity, offline demo stub. The AppKit window is a thin renderer over
/// these; the demo flag path needs no owner/network to exercise.
@Suite struct SignInWebTests {
    private func challenge(
        base: String = "https://microsoft.com/devicelogin",
        complete: String? = "https://microsoft.com/devicelogin?otc=WDJB-MJHT"
    ) -> DeviceCodeFlow.Challenge {
        DeviceCodeFlow.Challenge(
            deviceCode: "dc-secret", userCode: "WDJB-MJHT",
            verificationURI: base, verificationURIComplete: complete,
            expiresIn: 900, interval: 5
        )
    }

    // MARK: - Start URL

    @Test func startURLPrefersComplete() {
        #expect(SignInWeb.startURL(challenge: challenge())
            == "https://microsoft.com/devicelogin?otc=WDJB-MJHT")
    }

    @Test func startURLFallsBackToBase() {
        #expect(SignInWeb.startURL(challenge: challenge(complete: nil))
            == "https://microsoft.com/devicelogin")
    }

    @Test func startURLEmptyCompleteFallsBack() {
        #expect(SignInWeb.startURL(challenge: challenge(complete: ""))
            == "https://microsoft.com/devicelogin")
    }

    // MARK: - Failure copy

    @Test func failureMessagesAreDistinctAndActionable() {
        let denied = SignInFailure.denied.message
        let expired = SignInFailure.expired.message
        #expect(!denied.isEmpty)
        #expect(!expired.isEmpty)
        #expect(denied != expired)
        #expect(denied.localizedCaseInsensitiveContains("denied"))
        #expect(expired.localizedCaseInsensitiveContains("expired"))
        // Both point at the fix: Retry fetches a fresh code.
        #expect(denied.localizedCaseInsensitiveContains("retry"))
        #expect(expired.localizedCaseInsensitiveContains("retry"))
    }

    // MARK: - Notification identity

    @Test func signInInfoMatchesCategory() {
        #expect(SignInInfo.isSignIn(category: SignInInfo.categoryID, userInfo: [:]))
        #expect(!SignInInfo.isSignIn(category: ReplyInfo.categoryID, userInfo: [:]))
        #expect(!SignInInfo.isSignIn(category: "", userInfo: [:]))
    }

    @Test func signInInfoMarkerFallback() {
        // Marker alone (category lost) still routes to the window.
        #expect(SignInInfo.isSignIn(category: "", userInfo: SignInInfo.userInfo()))
        // Message userInfo never matches.
        #expect(!SignInInfo.isSignIn(category: "", userInfo: ReplyInfo.userInfo(chatID: "19:abc")))
    }

    // MARK: - Demo stub

    @Test func demoHTMLLabelsAndCode() {
        let html = SignInWeb.demoHTML(userCode: "AB12-CD34")
        #expect(html.contains("DEMO"))
        #expect(html.contains("AB12-CD34"))
        // Device-confirm layout: code box + Continue affordance.
        #expect(html.contains("Continue"))
        #expect(html.contains("code"))
    }

    @Test func demoHTMLDefaultCodeIsObviouslyFake() {
        #expect(SignInWeb.demoHTML().contains(SignInWeb.demoUserCode))
        #expect(SignInWeb.demoUserCode.contains("DEMO"))
    }

    @Test func demoHTMLEscapesCode() {
        let html = SignInWeb.demoHTML(userCode: "<script>alert(1)</script>")
        #expect(!html.contains("<script>alert(1)</script>"))
        #expect(html.contains("&lt;script&gt;"))
    }

    @Test func demoHTMLLoadsNothingExternal() {
        // Fully local: no links, no scripts, no remote resources.
        let html = SignInWeb.demoHTML()
        #expect(!html.contains("src=\"http"))
        #expect(!html.contains("href=\"http"))
        #expect(!html.lowercased().contains("<script"))
    }
}
