import AppKit
import CryptoKit
import Foundation
import TeamsCore

/// User-delegated auth for a work Teams account.
///
/// Primary flow: RFC 8628 device code (no redirect URI, so no reply-URL
/// registration needed on the reused Teams public client). Fallback: system
/// browser -> AAD authorize (PKCE S256, RFC 8252 loopback redirect) ->
/// token endpoint. Both end the same way: AAD access + refresh token ->
/// authsvc exchange -> skype token (+ regionGtms). Refresh token persists
/// in Keychain.
///
/// WHY DEVICE CODE FIRST: the loopback flow needs a redirect URI the
/// first-party client accepts; an unregistered path fails loud with
/// AADSTS50011 and its exact registrations are unknowable from outside.
/// Device code sidesteps that entirely and still handles MFA/CA (real
/// browser on microsoft.com).
///
/// WHY NOT ASWebAuthenticationSession: it can only intercept custom-scheme
/// callbacks, and a custom scheme must be registered on the OAuth client.
/// We reuse the Teams public client (no registration of our own), so no
/// custom scheme is available. Swap point is signInInteractive() if the
/// owner ever registers their own client ID.
public actor AuthManager {
    public enum AuthError: Error, Sendable {
        case noRefreshToken
        case needsSignIn(String)
        case network(String)
        case protocolError(String)
        case cancelled
        /// Owner declined the device-code request, or polling ran past
        /// the challenge expiry. Notify + offer retry, not a crash.
        case denied
        case expired
    }

    /// Sign-in transport. Device is default; loopback (+manual paste) stays
    /// as fallback via --auth loopback.
    public enum AuthMethod: String, Sendable {
        case device
        case loopback
    }

    public struct SkypeCredentials: Sendable {
        public let skypeToken: String
        /// Chat service base from regionGtms, e.g.
        /// https://amer.ng.msg.teams.microsoft.com
        public let chatServiceBase: String
    }

    private let store: TokenStore
    private let session: URLSession

    private var aadToken: String?
    private var aadExpiry: Date?
    /// Last seen expires_in (drives the keep-alive schedule).
    private var aadLifetime: TimeInterval = 3600
    private var skypeToken: String?
    private var skypeExpiry: Date?
    private var chatServiceBase: String = TeamsConstants.defaultChatService
    private var keepAliveTask: Task<Void, Never>?

    /// Fired when the refresh token dies (expiry/revocation). App posts a
    /// "sign-in needed" notification and reopens sign-in.
    public var onNeedsSignIn: (@Sendable (String) -> Void)?

    /// Fired when the device-code challenge arrives, before polling starts.
    /// App copies the user code, opens the browser, posts the notification.
    public var onDeviceCode: (@Sendable (DeviceCodeFlow.Challenge) -> Void)?

    public init(store: TokenStore = TokenStore()) {
        self.store = store
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
    }

    public func setNeedsSignInHandler(_ h: @escaping @Sendable (String) -> Void) {
        onNeedsSignIn = h
    }

    public func setDeviceCodeHandler(_ h: @escaping @Sendable (DeviceCodeFlow.Challenge) -> Void) {
        onDeviceCode = h
    }

    public var hasRefreshToken: Bool { store.readRefreshToken() != nil }

    /// Current AAD access token for trouter user.authenticate + registrar.
    /// Refreshes first so the token is valid.
    public func currentAADToken() async throws -> String {
        try await ensureAADToken()
        guard let t = aadToken else { throw AuthError.noRefreshToken }
        return t
    }

    public func signOut() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        store.clearRefreshToken()
        aadToken = nil
        skypeToken = nil
    }

    // MARK: - Keep-alive

    /// Proactive refresh loop: force-refreshes AAD + skype tokens at
    /// ~50% lifetime (KeepAlive math) so the session rolls indefinitely
    /// instead of dying at expiry. Transient failures retry with backoff;
    /// unrecoverable ones (invalid_grant/interaction_required) flow through
    /// the existing needsSignIn path (notify + reopen sign-in) and stop the
    /// loop. Idempotent; restart after interactive sign-in.
    public func startKeepAlive() {
        guard keepAliveTask == nil else { return }
        keepAliveTask = Task { await self.keepAliveLoop() }
    }

    public func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    private func keepAliveLoop() async {
        defer { keepAliveTask = nil }
        var failures = 0
        while !Task.isCancelled {
            let delay = failures > 0
                ? KeepAlive.retryDelay(failures: failures)
                : KeepAlive.refreshDelay(expiresIn: aadLifetime)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { break }
            do {
                try await keepAliveRefresh()
                failures = 0
            } catch AuthError.needsSignIn {
                break // already notified; App reopens sign-in
            } catch is CancellationError {
                break
            } catch {
                failures += 1
                Log.fault("keep-alive refresh failed (\(error)), retry in \(Int(KeepAlive.retryDelay(failures: failures)))s")
            }
        }
    }

    /// One forced refresh cycle (AAD + skype), always hitting the network.
    public func keepAliveRefresh() async throws {
        try await ensureAADToken(force: true)
        try await exchangeSkypeToken()
        Log.info("keep-alive: tokens refreshed proactively")
    }

    // MARK: - Steady state

    /// Valid skype credentials, refreshing AAD + skype tokens as needed.
    /// Throws needsSignIn when only interactive sign-in can proceed.
    public func ensureSkypeCredentials() async throws -> SkypeCredentials {
        if let sk = skypeToken, let exp = skypeExpiry, exp > Date().addingTimeInterval(300) {
            return SkypeCredentials(skypeToken: sk, chatServiceBase: chatServiceBase)
        }
        try await ensureAADToken()
        try await exchangeSkypeToken()
        guard let sk = skypeToken else { throw AuthError.protocolError("skype exchange returned no token") }
        return SkypeCredentials(skypeToken: sk, chatServiceBase: chatServiceBase)
    }

    /// Force re-exchange (e.g. after a 401 from chat REST or trouter).
    public func refreshSkypeCredentials() async throws -> SkypeCredentials {
        skypeToken = nil
        skypeExpiry = nil
        return try await ensureSkypeCredentials()
    }

    private func ensureAADToken(force: Bool = false) async throws {
        if !force, let t = aadToken, let exp = aadExpiry, exp > Date().addingTimeInterval(300) {
            _ = t
            return
        }
        guard let refresh = store.readRefreshToken() else { throw AuthError.noRefreshToken }
        var req = URLRequest(url: URL(string: TeamsConstants.tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form([
            "client_id": TeamsConstants.workClientID,
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "scope": TeamsConstants.primaryScope,
        ])
        let obj = try await postForm(req)
        if let err = obj["error"] as? String {
            let desc = (obj["error_description"] as? String) ?? err
            if err == "invalid_grant" || err == "interaction_required" {
                store.clearRefreshToken()
                throw needsSignIn("Refresh token rejected (\(err)): \(desc)")
            }
            throw AuthError.network("token refresh failed (\(err)): \(desc)")
        }
        guard let access = obj["access_token"] as? String else {
            throw AuthError.protocolError("token refresh response missing access_token")
        }
        aadToken = access
        aadLifetime = lifetime(from: obj)
        aadExpiry = Date().addingTimeInterval(aadLifetime)
        if let rolled = obj["refresh_token"] as? String, !rolled.isEmpty {
            store.writeRefreshToken(rolled)
        }
        learnOwner(from: access)
        Log.info("AAD token refreshed")
    }

    private func exchangeSkypeToken() async throws {
        guard let aad = aadToken else { throw AuthError.noRefreshToken }
        var req = URLRequest(url: URL(string: TeamsConstants.authzURLWork)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(aad)", forHTTPHeaderField: "Authorization")
        req.setValue("0", forHTTPHeaderField: "Content-Length")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AuthError.network("authz: no HTTP response") }
        guard http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let sk = tokens["skypeToken"] as? String
        else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 401 {
                aadToken = nil // force AAD refresh next try
                throw AuthError.network("authz 401 (AAD token rejected): \(body.prefix(200))")
            }
            throw AuthError.protocolError("authz HTTP \(http.statusCode): \(body.prefix(200))")
        }
        skypeToken = sk
        if let secs = (tokens["expiresIn"] as? Int).map(TimeInterval.init) ?? (tokens["expiresIn"] as? Double) {
            skypeExpiry = Date().addingTimeInterval(secs)
        } else {
            skypeExpiry = Date().addingTimeInterval(3600)
        }
        if let gtms = obj["regionGtms"] as? [String: Any],
           let chat = gtms["chatService"] as? String, !chat.isEmpty
        {
            chatServiceBase = chat
            Log.debug("regionGtms.chatService = \(chat)")
        }
        Log.info("skype token exchanged")
    }

    // MARK: - Interactive sign-in

    /// Full interactive sign-in. Device code by default (no redirect URI);
    /// loopback + system browser on request. Same swap point either way.
    public func signInInteractive(method: AuthMethod = .device) async throws {
        switch method {
        case .device: try await signInDevice()
        case .loopback: try await signInLoopback()
        }
    }

    // MARK: - Device code sign-in (primary, RFC 8628)

    /// Request a challenge, hand it to the App (clipboard + browser +
    /// notification), then poll the token endpoint to a terminal outcome.
    public func signInDevice() async throws {
        var req = URLRequest(url: URL(string: TeamsConstants.deviceCodeURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form([
            "client_id": TeamsConstants.workClientID,
            "scope": TeamsConstants.primaryScope,
        ])
        let obj = try await postForm(req)
        let challenge: DeviceCodeFlow.Challenge
        do {
            challenge = try DeviceCodeFlow.parseChallenge(obj)
        } catch let DeviceCodeFlow.ParseError.serverError(code, desc) {
            throw AuthError.network("devicecode request failed (\(code)): \(desc)")
        } catch {
            throw AuthError.protocolError("devicecode response malformed: \(error)")
        }
        Log.info("device challenge received, polling every \(challenge.interval)s")
        onDeviceCode?(challenge)
        try await pollDeviceToken(challenge)
    }

    private func pollDeviceToken(_ challenge: DeviceCodeFlow.Challenge) async throws {
        var interval = challenge.interval
        let start = Date()
        while true {
            let elapsed = Int(Date().timeIntervalSince(start))
            var req = URLRequest(url: URL(string: TeamsConstants.tokenURL)!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = form([
                "client_id": TeamsConstants.workClientID,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": challenge.deviceCode,
            ])
            let obj = try await postForm(req)
            switch DeviceCodeFlow.classifyPoll(
                obj,
                currentInterval: interval,
                elapsedSeconds: elapsed,
                expiresIn: challenge.expiresIn
            ) {
            case .keepWaiting(let delay):
                try await sleepOrCancel(seconds: delay)
            case .slowDown(let next):
                Log.debug("device poll slow_down, interval now \(next)s")
                interval = next
                try await sleepOrCancel(seconds: next)
            case .success(let access, let refresh, let secs):
                guard let refresh, !refresh.isEmpty else {
                    throw AuthError.protocolError("device flow returned no refresh token (offline_access missing?)")
                }
                try await storeFreshTokens(access: access, refresh: refresh, expiresIn: secs)
                return
            case .expired:
                throw AuthError.expired
            case .denied:
                throw AuthError.denied
            case .fatal(let code, let desc):
                throw AuthError.network("device poll failed (\(code)): \(desc)")
            }
        }
    }

    private func sleepOrCancel(seconds: Int) async throws {
        do {
            try await Task.sleep(nanoseconds: UInt64(max(seconds, 1)) * 1_000_000_000)
        } catch {
            throw AuthError.cancelled
        }
    }

    // MARK: - Loopback sign-in (fallback)

    /// Full browser sign-in. Starts the loopback listener FIRST (so the
    /// bound port is known), opens the system browser, waits for the
    /// callback, exchanges the code.
    public func signInLoopback() async throws {
        let pkce = PKCE.generate()
        let server = try LoopbackServer()
        let state = UUID().uuidString
        let nonce = UUID().uuidString
        do {
            try await server.start()
        } catch {
            throw AuthError.network("loopback bind failed")
        }
        guard let port = server.port, port != 0 else {
            throw AuthError.network("loopback bind failed (no port)")
        }
        let redirect = "http://\(TeamsConstants.loopbackHost):\(port)\(TeamsConstants.loopbackPath)"
        var comps = URLComponents(string: TeamsConstants.authorizeURL)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: TeamsConstants.workClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: TeamsConstants.primaryScope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        guard let url = comps.url else { throw AuthError.protocolError("bad authorize URL") }
        Log.info("opening browser for sign-in")
        await MainActor.run { NSWorkspace.shared.open(url) }
        let result: LoopbackServer.Result
        do {
            result = try await server.waitForCallback(timeoutSeconds: 300)
        } catch {
            throw AuthError.cancelled
        }
        guard result.state == state else { throw AuthError.protocolError("state mismatch (CSRF guard)") }
        try await exchangeCode(result.code, verifier: pkce.verifier, redirectURI: redirect)
    }

    /// Fixed loopback port for the manual paste flow. Nothing listens there;
    /// the browser shows connection-refused but keeps ?code= in the URL bar.
    public static let manualFlowPort: UInt16 = 8765

    /// Manual fallback (purple-teams style): owner pastes the full redirect
    /// URL or bare code after signing in. Needs the same PKCE verifier +
    /// redirect URI as the authorize URL, so this path reuses a fresh
    /// authorize URL printed to stderr and opened in the browser.
    public func authorizeURLForManualFlow() -> (url: URL, verifier: String, redirectURI: String, state: String) {
        let pkce = PKCE.generate()
        let state = UUID().uuidString
        let redirect = "http://\(TeamsConstants.loopbackHost):\(Self.manualFlowPort)\(TeamsConstants.loopbackPath)"
        var comps = URLComponents(string: TeamsConstants.authorizeURL)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: TeamsConstants.workClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: TeamsConstants.primaryScope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return (comps.url!, pkce.verifier, redirect, state)
    }

    /// Exchange a pasted redirect URL / bare code from the manual flow.
    public func exchangeManualCode(_ text: String, verifier: String, redirectURI: String, state: String) async throws {
        let code: String
        if text.contains("code=") {
            guard let comps = URLComponents(string: text),
                  let c = comps.queryItems?.first(where: { $0.name == "code" })?.value
            else { throw AuthError.protocolError("no code= in pasted URL") }
            if let s = comps.queryItems?.first(where: { $0.name == "state" })?.value, s != state {
                throw AuthError.protocolError("state mismatch (CSRF guard)")
            }
            code = c
        } else {
            code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try await exchangeCode(code, verifier: verifier, redirectURI: redirectURI)
    }

    private func exchangeCode(_ code: String, verifier: String, redirectURI: String) async throws {
        var req = URLRequest(url: URL(string: TeamsConstants.tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form([
            "client_id": TeamsConstants.workClientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
            "scope": TeamsConstants.primaryScope,
        ])
        let obj = try await postForm(req)
        if let err = obj["error"] as? String {
            let desc = (obj["error_description"] as? String) ?? err
            throw AuthError.network("code exchange failed (\(err)): \(desc)")
        }
        guard let access = obj["access_token"] as? String,
              let refresh = obj["refresh_token"] as? String
        else { throw AuthError.protocolError("code exchange response missing tokens") }
        try await storeFreshTokens(access: access, refresh: refresh, expiresIn: nil, raw: obj)
    }

    /// Shared tail for both sign-in transports: persist refresh token,
    /// learn owner, exchange the skype token.
    private func storeFreshTokens(access: String, refresh: String, expiresIn: Int?, raw: [String: Any]? = nil) async throws {
        aadToken = access
        if let secs = expiresIn {
            aadLifetime = TimeInterval(secs)
        } else if let raw {
            aadLifetime = lifetime(from: raw)
        } else {
            aadLifetime = 3600
        }
        aadExpiry = Date().addingTimeInterval(aadLifetime)
        store.writeRefreshToken(refresh)
        learnOwner(from: access)
        try await exchangeSkypeToken()
        Log.info("sign-in complete")
    }

    // MARK: - Owner identity

    /// Owner MRI learned from the AAD token oid claim (8:orgid:{oid}).
    public func ownerMRI(configured: String) -> String? {
        if !configured.isEmpty { return configured }
        return store.readOwnerMRI()
    }

    private func learnOwner(from accessToken: String) {
        guard let claims = try? JWT.decode(accessToken) else {
            Log.debug("AAD token is opaque, owner not learned")
            return
        }
        if let oid = claims.oid, !oid.isEmpty {
            store.writeOwnerMRI("8:orgid:\(oid)")
            Log.info("owner MRI learned from token")
        }
        if let upn = claims.upn, !upn.isEmpty {
            store.writeOwnerUPN(upn)
            Log.info("owner UPN learned: \(upn)")
        }
        if let name = claims.name {
            Log.debug("owner name claim: \(name)")
        }
    }

    // MARK: - Helpers

    private func needsSignIn(_ msg: String) -> AuthError {
        Log.fault(msg)
        onNeedsSignIn?(msg)
        return .needsSignIn(msg)
    }

    private func form(_ fields: [String: String]) -> Data {
        var c = URLComponents()
        c.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((c.percentEncodedQuery ?? "").utf8)
    }

    private func postForm(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await session.data(for: req)
        guard resp is HTTPURLResponse else { throw AuthError.network("token endpoint: no HTTP response") }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.protocolError("token endpoint returned non-JSON")
        }
        return obj
    }

    private func lifetime(from obj: [String: Any]) -> TimeInterval {
        if let s = obj["expires_in"] as? Int { return TimeInterval(s) }
        else if let s = obj["expires_in"] as? Double { return s }
        else if let s = obj["expires_in"] as? String, let v = Double(s) { return v }
        else { return 3600 }
    }

    private func expiry(from obj: [String: Any]) -> Date {
        Date().addingTimeInterval(lifetime(from: obj))
    }
}

/// RFC 7636 PKCE, S256 (roshank8s pattern).
struct PKCE: Sendable {
    let verifier: String
    let challenge: String

    static func generate() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URLEncodedString()
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()
        return PKCE(verifier: verifier, challenge: challenge)
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
