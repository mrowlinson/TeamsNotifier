import Foundation
import Testing
@testable import TeamsCore

/// Device-code flow: parsers + poll state machine + harness runs.
/// Live flow (real challenge + owner approval) needs the owner; these cover
/// everything up to the network edge.
@Suite struct DeviceCodeFlowTests {
    // MARK: - Challenge parser

    @Test func parsesChallenge() throws {
        let body = #"{"device_code":"dc-secret","user_code":"WDJB-MJHT","verification_uri":"https://microsoft.com/devicelogin","verification_uri_complete":"https://microsoft.com/devicelogin?otc=WDJB-MJHT","expires_in":900,"interval":5,"message":"..."}"#
        let c = try DeviceCodeFlow.parseChallenge(Data(body.utf8))
        #expect(c.deviceCode == "dc-secret")
        #expect(c.userCode == "WDJB-MJHT")
        #expect(c.verificationURI == "https://microsoft.com/devicelogin")
        #expect(c.verificationURIComplete == "https://microsoft.com/devicelogin?otc=WDJB-MJHT")
        #expect(c.expiresIn == 900)
        #expect(c.interval == 5)
    }

    @Test func challengeDefaults() throws {
        // AAD always sends expires_in/interval, but be lenient.
        let body = #"{"device_code":"d","user_code":"U","verification_uri":"https://microsoft.com/devicelogin"}"#
        let c = try DeviceCodeFlow.parseChallenge(Data(body.utf8))
        #expect(c.expiresIn == 900)
        #expect(c.interval == 5)
        #expect(c.verificationURIComplete == nil)
    }

    @Test func challengeMissingField() {
        let body = #"{"user_code":"U","verification_uri":"https://x"}"#
        #expect(throws: DeviceCodeFlow.ParseError.missingField("device_code")) {
            try DeviceCodeFlow.parseChallenge(Data(body.utf8))
        }
    }

    @Test func challengeServerError() {
        let body = #"{"error":"invalid_client","error_description":"bad id"}"#
        #expect(throws: DeviceCodeFlow.ParseError.serverError(code: "invalid_client", description: "bad id")) {
            try DeviceCodeFlow.parseChallenge(Data(body.utf8))
        }
    }

    @Test func challengeNotJSON() {
        #expect(throws: DeviceCodeFlow.ParseError.notJSON) {
            try DeviceCodeFlow.parseChallenge(Data("nope".utf8))
        }
    }

    // MARK: - Poll classifier

    @Test func pollPendingKeepsWaiting() {
        let o = DeviceCodeFlow.classifyPoll(
            ["error": "authorization_pending"], currentInterval: 5, elapsedSeconds: 10, expiresIn: 900
        )
        #expect(o == .keepWaiting(delay: 5))
    }

    @Test func pollSuccess() {
        let o = DeviceCodeFlow.classifyPoll(
            ["access_token": "a", "refresh_token": "r", "expires_in": 3600],
            currentInterval: 5, elapsedSeconds: 10, expiresIn: 900
        )
        #expect(o == .success(accessToken: "a", refreshToken: "r", expiresIn: 3600))
    }

    @Test func pollSlowDownAddsFive() {
        let o = DeviceCodeFlow.classifyPoll(
            ["error": "slow_down"], currentInterval: 5, elapsedSeconds: 10, expiresIn: 900
        )
        #expect(o == .slowDown(newInterval: 10))
    }

    @Test func pollExpiredAndDenied() {
        for err in ["expired_token", "code_expired"] {
            let o = DeviceCodeFlow.classifyPoll(
                ["error": err], currentInterval: 5, elapsedSeconds: 10, expiresIn: 900
            )
            #expect(o == .expired)
        }
        for err in ["authorization_declined", "access_denied"] {
            let o = DeviceCodeFlow.classifyPoll(
                ["error": err], currentInterval: 5, elapsedSeconds: 10, expiresIn: 900
            )
            #expect(o == .denied)
        }
    }

    @Test func pollFatalAndMalformed() {
        let o = DeviceCodeFlow.classifyPoll(
            ["error": "invalid_grant", "error_description": "nope"],
            currentInterval: 5, elapsedSeconds: 10, expiresIn: 900
        )
        #expect(o == .fatal(code: "invalid_grant", description: "nope"))
        let bad = DeviceCodeFlow.classifyPoll(
            ["unexpected": 1], currentInterval: 5, elapsedSeconds: 10, expiresIn: 900
        )
        #expect(bad == .fatal(code: "bad_response", description: "token poll returned neither tokens nor error"))
        let nonJSON = DeviceCodeFlow.classifyPoll(
            data: Data("html".utf8), currentInterval: 5, elapsedSeconds: 10, expiresIn: 900
        )
        #expect(nonJSON == .fatal(code: "bad_response", description: "token poll returned non-JSON"))
    }

    @Test func pollClientSideExpiry() {
        // Server silent-expired: stop even on authorization_pending.
        let o = DeviceCodeFlow.classifyPoll(
            ["error": "authorization_pending"], currentInterval: 5, elapsedSeconds: 900, expiresIn: 900
        )
        #expect(o == .expired)
    }

    // MARK: - Harness (full loop, no network)

    private func challenge(interval: Int = 5, expiresIn: Int = 900) -> DeviceCodeFlow.Challenge {
        DeviceCodeFlow.Challenge(
            deviceCode: "d", userCode: "U",
            verificationURI: "https://microsoft.com/devicelogin",
            expiresIn: expiresIn, interval: interval
        )
    }

    @Test func harnessPendingThenSuccess() {
        let r = DeviceCodeFlow.runPollLoop(challenge: challenge()) { n in
            n < 3 ? ["error": "authorization_pending"]
                : ["access_token": "a", "refresh_token": "r", "expires_in": 3600]
        }
        #expect(r.outcome == .success(accessToken: "a", refreshToken: "r", expiresIn: 3600))
        #expect(r.polls == 3)
        #expect(r.delays == [5, 5]) // interval respected on every wait
    }

    @Test func harnessSlowDownBackoff() {
        let r = DeviceCodeFlow.runPollLoop(challenge: challenge()) { n in
            switch n {
            case 1: ["error": "authorization_pending"]
            case 2: ["error": "slow_down"]
            default: ["access_token": "a", "expires_in": 3600]
            }
        }
        #expect(r.outcome == .success(accessToken: "a", refreshToken: nil, expiresIn: 3600))
        #expect(r.polls == 3)
        #expect(r.delays == [5, 10]) // slow_down bumps interval by 5
    }

    @Test func harnessExpired() {
        let r = DeviceCodeFlow.runPollLoop(challenge: challenge(expiresIn: 60)) { n in
            n < 3 ? ["error": "authorization_pending"] : ["error": "expired_token"]
        }
        #expect(r.outcome == .expired)
        #expect(r.polls == 3)
    }

    @Test func harnessDenied() {
        let r = DeviceCodeFlow.runPollLoop(challenge: challenge()) { n in
            n < 2 ? ["error": "authorization_pending"] : ["error": "authorization_declined"]
        }
        #expect(r.outcome == .denied)
        #expect(r.polls == 2)
    }

    @Test func harnessFatalStops() {
        let r = DeviceCodeFlow.runPollLoop(challenge: challenge()) { n in
            n < 2 ? ["error": "authorization_pending"] : ["error": "invalid_grant"]
        }
        if case .fatal(let code, _) = r.outcome {
            #expect(code == "invalid_grant")
        } else {
            Issue.record("expected fatal, got \(r.outcome)")
        }
        #expect(r.polls == 2)
    }

    @Test func harnessNeverPollsPastExpiry() {
        // Pending forever: client-side guard must terminate the loop.
        let r = DeviceCodeFlow.runPollLoop(challenge: challenge(interval: 5, expiresIn: 20)) { _ in
            ["error": "authorization_pending"]
        }
        #expect(r.outcome == .expired)
        #expect(r.polls == 5) // elapsed 0,5,10,15 then 20 >= expires_in
    }
}
