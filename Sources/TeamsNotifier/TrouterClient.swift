import Foundation
import TeamsCore

/// Trouter realtime client: bootstrap -> socket.io session -> WebSocket ->
/// authenticate -> register -> receive. Reconnects with backoff forever.
/// Protocol per purple-teams teams_trouter.c + agent-messenger trouter.ts.
public actor TrouterClient {
    public enum State: Sendable {
        case stopped
        case connecting(String)
        case connected
        case backoff(Int)
    }

    private struct Bootstrap: Sendable {
        let socketIO: String
        let surl: String
        let connectParams: [String: String]
        let ccid: String?
    }

    private let auth: AuthManager
    private let session: URLSession
    private let onMessage: @Sendable (EventMessage.Message, Bool) async -> Void
    private let onState: @Sendable (State) async -> Void

    private var task: URLSessionWebSocketTask?
    private var running = false
    private var sequence = 1
    private var seenIDs: [String] = [] // ring, cap 10 (purple-teams buffer)
    private var endpointID = UUID().uuidString

    public init(
        auth: AuthManager,
        onMessage: @escaping @Sendable (EventMessage.Message, Bool) async -> Void,
        onState: @escaping @Sendable (State) async -> Void
    ) {
        self.auth = auth
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
        self.onMessage = onMessage
        self.onState = onState
    }

    // MARK: - Run loop

    public func run() async {
        running = true
        var failures = 0
        while running {
            do {
                await onState(.connecting("trouter"))
                try await connectAndReceive()
                failures = 0 // clean close (server-side); reconnect immediately
                Log.info("trouter closed, reconnecting")
            } catch is CancellationError {
                break
            } catch {
                failures += 1
                let wait = min(5 * failures, 60)
                Log.fault("trouter error: \(error) (retry in \(wait)s)")
                await onState(.backoff(wait))
                try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
            }
        }
        await onState(.stopped)
    }

    public func stop() {
        running = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // MARK: - Connect

    private func connectAndReceive() async throws {
        let creds = try await auth.ensureSkypeCredentials()
        guard running else { throw CancellationError() }

        // 1. Bootstrap: POST /v4/a?epid=... (purple-teams + agent-messenger).
        let info = try await bootstrap(skypeToken: creds.skypeToken)

        // 2. socket.io session id via authenticated GET.
        let query = TrouterFrame.query(connectParams: info.connectParams, endpointID: endpointID, ccid: info.ccid)
        let sio = info.socketIO.hasSuffix("/") ? info.socketIO : info.socketIO + "/"
        let sessionURL = URL(string: "\(sio)socket.io/1/?\(query)")!
        let sid = try await socketSessionID(url: sessionURL, skypeToken: creds.skypeToken)

        // 3. WebSocket connect with X-Skypetoken header.
        let wsURL = URL(string: "\(sio)socket.io/1/websocket/\(sid)?\(query)")!
        var wsReq = URLRequest(url: wsURL)
        wsReq.setValue(creds.skypeToken, forHTTPHeaderField: "X-Skypetoken")
        wsReq.setValue(TeamsConstants.userAgent, forHTTPHeaderField: "User-Agent")
        let ws = session.webSocketTask(with: wsReq)
        task = ws
        sequence = 1
        ws.resume()
        Log.info("trouter WS connected (sid \(sid.prefix(8))...)")

        // 4. Wait for `1::` hello, then authenticate + register.
        try await waitForHello(ws)
        let aad = try await currentAADToken()
        try await send(ws, TrouterFrame.authenticate(connectParams: info.connectParams, idToken: aad))
        try await send(ws, TrouterFrame.activity(sequence: nextSequence()))
        try await registerAll(surl: info.surl, skypeToken: creds.skypeToken, aadToken: aad)
        await onState(.connected)

        // 5. Ping loop + receive loop.
        async let pings: Void = pingLoop(ws)
        async let receive: Void = receiveLoop(ws, surl: info.surl)
        try await pings
        try await receive
    }

    private func currentAADToken() async throws -> String {
        // AAD token is not exposed; re-derive via ensure path is wasteful.
        // Instead: exchange path already ran in ensureSkypeCredentials, but we
        // need the raw AAD token for user.authenticate + registrar. AuthManager
        // exposes it via a dedicated accessor.
        try await auth.currentAADToken()
    }

    private func nextSequence() -> Int {
        defer { sequence += 1 }
        return sequence
    }

    // MARK: - HTTP steps

    private func bootstrap(skypeToken: String) async throws -> Bootstrap {
        var comps = URLComponents(string: TeamsConstants.trouterBootstrap)!
        comps.queryItems = [URLQueryItem(name: "epid", value: endpointID)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(skypeToken, forHTTPHeaderField: "x-skypetoken")
        req.setValue("0", forHTTPHeaderField: "Content-Length")
        req.setValue(TeamsConstants.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            return try await parseBootstrap(req)
        } catch BootstrapError.unauthorized {
            Log.info("trouter bootstrap 401, refreshing skype token once")
            let fresh = try await auth.refreshSkypeCredentials()
            req.setValue(fresh.skypeToken, forHTTPHeaderField: "x-skypetoken")
            return try await parseBootstrap(req)
        }
    }

    private enum BootstrapError: Error { case unauthorized }

    private func parseBootstrap(_ req: URLRequest) async throws -> Bootstrap {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AuthManager.AuthError.network("bootstrap: no HTTP response") }
        if http.statusCode == 401 { throw BootstrapError.unauthorized }
        guard http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sio = obj["socketio"] as? String,
              let surl = obj["surl"] as? String,
              let cp = obj["connectparams"] as? [String: String]
        else {
            throw AuthManager.AuthError.protocolError("bootstrap HTTP \(http.statusCode): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        return Bootstrap(socketIO: sio, surl: surl, connectParams: cp, ccid: obj["ccid"] as? String)
    }

    private func socketSessionID(url: URL, skypeToken: String) async throws -> String {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(skypeToken, forHTTPHeaderField: "X-Skypetoken")
        req.setValue(TeamsConstants.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthManager.AuthError.protocolError("socket.io session HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        guard let sid = TrouterFrame.parseSessionID(body) else {
            throw AuthManager.AuthError.protocolError("socket.io session: unparseable body")
        }
        return sid
    }

    private func registerAll(surl: String, skypeToken: String, aadToken: String) async throws {
        for spec in TeamsConstants.registrations {
            try await registerOne(spec, surl: surl, skypeToken: skypeToken, aadToken: aadToken)
        }
        Log.info("trouter registrations done")
    }

    func registerOne(_ spec: TeamsConstants.Registration, surl: String, skypeToken: String, aadToken: String) async throws {
        let regID = spec.reuseEndpointID ? endpointID : UUID().uuidString
        let payload: [String: Any] = [
            "clientDescription": [
                "appId": spec.appID,
                "aesKey": "",
                "languageId": "en-US",
                "platform": "edge",
                "templateKey": spec.templateKey,
                "platformUIVersion": TeamsConstants.clientInfoVersion,
            ],
            "registrationId": regID,
            "nodeId": "",
            "transports": ["TROUTER": [["context": "", "path": "\(surl)\(spec.pathSuffix)", "ttl": TeamsConstants.trouterTTL]]],
        ]
        var req = URLRequest(url: URL(string: TeamsConstants.registrarURLWork)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(skypeToken, forHTTPHeaderField: "X-Skypetoken")
        req.setValue("Bearer \(aadToken)", forHTTPHeaderField: "Authorization")
        req.setValue(TeamsConstants.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, RegistrarResponse.isSuccess(statusCode: http.statusCode) else {
            throw AuthManager.AuthError.protocolError("registrar \(spec.appID) HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(String(data: data, encoding: .utf8)?.prefix(160) ?? "")")
        }
        Log.debug("registrar \(spec.appID) HTTP \(http.statusCode)")
    }

    // MARK: - WS loops

    private func waitForHello(_ ws: URLSessionWebSocketTask) async throws {
        while running {
            let msg = try await ws.receive()
            if case .string(let s) = msg, TrouterFrame.isHello(s) { return }
        }
        throw CancellationError()
    }

    private func pingLoop(_ ws: URLSessionWebSocketTask) async throws {
        while running {
            try? await Task.sleep(nanoseconds: UInt64(TeamsConstants.pingIntervalSeconds) * 1_000_000_000)
            guard running else { return }
            try await send(ws, TrouterFrame.ping(sequence: nextSequence()))
            Log.debug("trouter ping sent")
        }
    }

    private func receiveLoop(_ ws: URLSessionWebSocketTask, surl: String) async throws {
        while running {
            let msg = try await ws.receive()
            guard case .string(let frame) = msg else { continue }
            try await handleFrame(frame, ws: ws, surl: surl)
        }
    }

    private func handleFrame(_ frame: String, ws: URLSessionWebSocketTask, surl: String) async throws {
        if TrouterFrame.isHello(frame) {
            // Re-hello (server restart): re-authenticate like first hello.
            let aad = try await currentAADToken()
            // connectparams are not retained; re-auth needs them. Reconnect
            // cleanly instead (cheap, correct).
            Log.info("trouter re-hello, reconnecting")
            _ = aad
            task?.cancel(with: .goingAway, reason: nil)
            throw Reconnect.wanted
        }
        if let req = TrouterFrame.parseRequest(frame) {
            try await send(ws, TrouterFrame.requestAck(requestID: req.id))
            await handleRequest(req)
            return
        }
        if frame.hasPrefix("5:") {
            if let ack = TrouterFrame.eventAck(for: frame) {
                try await send(ws, ack)
            }
            if TrouterFrame.isMessageLoss(frame) {
                Log.fault("trouter.message_loss, re-registering worker")
                let creds = try await auth.ensureSkypeCredentials()
                let aad = try await currentAADToken()
                try await registerOne(TeamsConstants.messageLossResubscribe, surl: surl, skypeToken: creds.skypeToken, aadToken: aad)
            }
            return
        }
        // "6:..." acks and anything else: ignore.
    }

    private func handleRequest(_ req: TrouterFrame.Request) async {
        guard let url = req.url else { return }
        guard url.hasSuffix("/messaging") else {
            Log.debug("trouter: ignoring \(url)")
            return
        }
        let obj: [String: Any]
        do {
            obj = try EventMessage.decodeBody(headers: req.headers, body: req.body)
        } catch {
            Log.fault("trouter: body decode failed: \(error)")
            return
        }
        guard let (message, isEdit) = EventMessage.parse(obj) else { return } // presence etc
        // Dedup (purple-teams 10-buffer).
        if !message.messageID.isEmpty {
            if seenIDs.contains(message.messageID) { return }
            seenIDs.append(message.messageID)
            if seenIDs.count > 10 { seenIDs.removeFirst(seenIDs.count - 10) }
        }
        await onMessage(message, isEdit)
    }

    private func send(_ ws: URLSessionWebSocketTask, _ text: String) async throws {
        try await ws.send(.string(text))
    }

    private enum Reconnect: Error { case wanted }
}
