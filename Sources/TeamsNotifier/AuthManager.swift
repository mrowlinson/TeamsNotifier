import AppKit
import CryptoKit
import Foundation
import TeamsCore

/// User-delegated auth for a work Teams account.
///
/// Flow (purple-teams work branch + ost work(), PKCE added per roshank8s):
/// system browser -> AAD authorize (organizations, Teams desktop public
/// client ID, PKCE S256) -> loopback redirect captures code -> token
/// endpoint -> AAD access token + refresh token -> authsvc exchange ->
/// skype token (+ regionGtms). Refresh token persists in Keychain.
///
/// WHY NOT ASWebAuthenticationSession: it can only intercept custom-scheme
/// callbacks, and a custom scheme must be registered on the OAuth client.
/// We reuse the Teams public client (no registration of our own), so no
/// custom scheme is available; RFC 8252 loopback + system browser is the
/// working shape for this client. Handles MFA/CA (real browser). Swap point
/// is signInInteractive() if the owner ever registers their own client ID.
public actor AuthManager {
    public enum AuthError: Error, Sendable {
        case noRefreshToken
        case needsSignIn(String)
        case network(String)
        case protocolError(String)
        case cancelled
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
    private var skypeToken: String?
    private var skypeExpiry: Date?
    private var chatServiceBase: String = TeamsConstants.defaultChatService

    /// Fired when the refresh token dies (expiry/revocation). App posts a
    /// "sign-in needed" notification and reopens sign-in.
    public var onNeedsSignIn: (@Sendable (String) -> Void)?

    public init(store: TokenStore = TokenStore()) {
        self.store = store
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
    }

    public func setNeedsSignInHandler(_ h: @escaping @Sendable (String) -> Void) {
        onNeedsSignIn = h
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
        store.clearRefreshToken()
        aadToken = nil
        skypeToken = nil
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

    private func ensureAADToken() async throws {
        if let t = aadToken, let exp = aadExpiry, exp > Date().addingTimeInterval(300) {
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
        aadExpiry = expiry(from: obj)
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

    /// Full browser sign-in. Opens the system browser, waits for the
    /// loopback callback, exchanges the code.
    public func signInInteractive() async throws {
        let pkce = PKCE.generate()
        let server = try LoopbackServer()
        let state = UUID().uuidString
        let nonce = UUID().uuidString
        guard let port = server.port else { throw AuthError.network("loopback bind failed") }
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
        aadToken = access
        aadExpiry = expiry(from: obj)
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

    private func expiry(from obj: [String: Any]) -> Date {
        let secs: TimeInterval
        if let s = obj["expires_in"] as? Int { secs = TimeInterval(s) }
        else if let s = obj["expires_in"] as? Double { secs = s }
        else if let s = obj["expires_in"] as? String, let v = Double(s) { secs = v }
        else { secs = 3600 }
        return Date().addingTimeInterval(secs)
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
