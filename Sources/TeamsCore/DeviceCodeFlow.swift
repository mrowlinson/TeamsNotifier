import Foundation

/// RFC 8628 device authorization grant, pure half: response parsers + poll
/// state machine. No networking here; AuthManager drives the HTTP calls and
/// App owns the UX (clipboard, browser, notifications).
///
/// AAD endpoints (v2.0, organizations tenant):
///   POST .../oauth2/v2.0/devicecode  -> DeviceCodeResponse
///   POST .../oauth2/v2.0/token with grant_type
///     urn:ietf:params:oauth:grant-type:device_code -> tokens or error
public enum DeviceCodeFlow {
    // MARK: - Device authorization response

    public struct Challenge: Sendable, Equatable {
        /// Long device identifier for token polls (secret, never shown).
        public let deviceCode: String
        /// Short code the owner types (shown + copied to clipboard).
        public let userCode: String
        /// Page to open in the default browser.
        public let verificationURI: String
        /// Complete URI with code prefilled, when the server sends one.
        public let verificationURIComplete: String?
        /// Seconds until device_code expires.
        public let expiresIn: Int
        /// Minimum seconds between token polls.
        public let interval: Int

        public init(
            deviceCode: String,
            userCode: String,
            verificationURI: String,
            verificationURIComplete: String? = nil,
            expiresIn: Int,
            interval: Int
        ) {
            self.deviceCode = deviceCode
            self.userCode = userCode
            self.verificationURI = verificationURI
            self.verificationURIComplete = verificationURIComplete
            self.expiresIn = expiresIn
            self.interval = interval
        }
    }

    public enum ParseError: Error, Sendable, Equatable {
        case notJSON
        case missingField(String)
        case serverError(code: String, description: String)
    }

    /// Parse a devicecode endpoint response body. Throws serverError when
    /// the body carries an OAuth error object.
    public static func parseChallenge(_ data: Data) throws -> Challenge {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notJSON
        }
        return try parseChallenge(obj)
    }

    public static func parseChallenge(_ obj: [String: Any]) throws -> Challenge {
        if let err = obj["error"] as? String {
            throw ParseError.serverError(code: err, description: (obj["error_description"] as? String) ?? err)
        }
        func str(_ key: String) throws -> String {
            guard let v = obj[key] as? String, !v.isEmpty else {
                throw ParseError.missingField(key)
            }
            return v
        }
        func int(_ key: String, fallback: Int) -> Int {
            if let v = obj[key] as? Int { return v }
            if let v = obj[key] as? Double { return Int(v) }
            if let v = obj[key] as? String, let n = Int(v) { return n }
            return fallback
        }
        return Challenge(
            deviceCode: try str("device_code"),
            userCode: try str("user_code"),
            verificationURI: try str("verification_uri"),
            verificationURIComplete: obj["verification_uri_complete"] as? String,
            expiresIn: int("expires_in", fallback: 900),
            interval: int("interval", fallback: 5)
        )
    }

    // MARK: - Token poll

    /// One poll attempt's outcome, after classifying the token response.
    public enum PollOutcome: Sendable, Equatable {
        /// Keep polling after `delay` seconds (authorization_pending).
        case keepWaiting(delay: Int)
        /// Server says slow_down: keep polling with the new interval.
        case slowDown(newInterval: Int)
        case success(accessToken: String, refreshToken: String?, expiresIn: Int)
        case expired
        case denied
        case fatal(code: String, description: String)
    }

    /// Classify a token endpoint poll body against current poll state.
    /// Pure: no clock reads; caller passes elapsed seconds.
    public static func classifyPoll(
        _ obj: [String: Any],
        currentInterval: Int,
        elapsedSeconds: Int,
        expiresIn: Int
    ) -> PollOutcome {
        if let access = obj["access_token"] as? String, !access.isEmpty {
            let refresh = obj["refresh_token"] as? String
            let secs: Int
            if let s = obj["expires_in"] as? Int { secs = s }
            else if let s = obj["expires_in"] as? Double { secs = Int(s) }
            else if let s = obj["expires_in"] as? String, let v = Int(s) { secs = v }
            else { secs = 3600 }
            return .success(accessToken: access, refreshToken: refresh, expiresIn: secs)
        }
        guard let err = obj["error"] as? String else {
            return .fatal(code: "bad_response", description: "token poll returned neither tokens nor error")
        }
        let desc = (obj["error_description"] as? String) ?? err
        switch err {
        case "authorization_pending":
            // Local expiry guard: server usually reports expired_token, but
            // stop client-side too so polling cannot run past expires_in.
            if elapsedSeconds >= expiresIn { return .expired }
            return .keepWaiting(delay: currentInterval)
        case "slow_down":
            return .slowDown(newInterval: currentInterval + 5)
        case "expired_token", "code_expired":
            return .expired
        case "authorization_declined", "access_denied":
            return .denied
        default:
            return .fatal(code: err, description: desc)
        }
    }

    public static func classifyPoll(
        data: Data,
        currentInterval: Int,
        elapsedSeconds: Int,
        expiresIn: Int
    ) -> PollOutcome {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .fatal(code: "bad_response", description: "token poll returned non-JSON")
        }
        return classifyPoll(obj, currentInterval: currentInterval, elapsedSeconds: elapsedSeconds, expiresIn: expiresIn)
    }

    // MARK: - Poll driver (harness-friendly)

    /// Minimal poll loop extracted for tests: given a responder closure that
    /// stands in for the token endpoint, run the state machine to a terminal
    /// outcome. `sleep` is injected so tests skip real waiting; production
    /// passes Task.sleep. Returns terminal outcome + poll count + delays used.
    public struct HarnessResult: Sendable, Equatable {
        public let outcome: PollOutcome
        public let polls: Int
        public let delays: [Int]

        public init(outcome: PollOutcome, polls: Int, delays: [Int]) {
            self.outcome = outcome
            self.polls = polls
            self.delays = delays
        }
    }

    public static func runPollLoop(
        challenge: Challenge,
        respond: (Int) -> [String: Any],
        sleep: (Int) -> Void = { _ in }
    ) -> HarnessResult {
        var interval = challenge.interval
        var elapsed = 0
        var delays: [Int] = []
        var n = 0
        while true {
            n += 1
            let outcome = classifyPoll(
                respond(n),
                currentInterval: interval,
                elapsedSeconds: elapsed,
                expiresIn: challenge.expiresIn
            )
            switch outcome {
            case .keepWaiting(let delay):
                delays.append(delay)
                sleep(delay)
                elapsed += delay
                continue
            case .slowDown(let next):
                interval = next
                delays.append(next)
                sleep(next)
                elapsed += next
                continue
            case .success, .expired, .denied, .fatal:
                return HarnessResult(outcome: outcome, polls: n, delays: delays)
            }
        }
    }
}
