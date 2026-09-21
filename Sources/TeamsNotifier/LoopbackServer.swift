import Foundation
import Network

/// RFC 8252 loopback redirect receiver: listens on 127.0.0.1 (ephemeral
/// port), captures one GET /callback?code=...&state=... from the system
/// browser, answers with a human-readable page, then stops.
public final class LoopbackServer: Sendable {
    public struct Result: Sendable {
        public let code: String
        public let state: String?
    }

    public enum Error: Swift.Error, Sendable {
        case bindFailed
        case timeout
        case missingCode
    }

    private let listener: NWListener
    private let state = Locked<State>(State())

    private struct State {
        var continuation: CheckedContinuation<Result, Swift.Error>?
        var done = false
    }

    public init() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let port = NWEndpoint.Port.any
        guard let listener = try? NWListener(using: params, on: port) else {
            throw Error.bindFailed
        }
        // Bind explicitly to loopback (NWListener default binds all).
        listener.service = nil
        self.listener = listener
    }

    public var port: UInt16? {
        listener.port?.rawValue
    }

    /// Start listening and wait for one callback. Throws on timeout.
    public func waitForCallback(timeoutSeconds: UInt = 300) async throws -> Result {
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: .global(qos: .userInitiated))
        // NWListener starts async; poll briefly for the bound port.
        let deadline = Date().addingTimeInterval(5)
        while port == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard port != nil else { throw Error.bindFailed }
        defer { listener.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            state.withLock { $0.continuation = cont }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                self.state.withLock {
                    if !$0.done, let c = $0.continuation {
                        $0.done = true
                        $0.continuation = nil
                        c.resume(throwing: Error.timeout)
                    }
                }
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            // GET /callback?code=..&state=.. HTTP/1.1
            let target = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            var code: String?
            var stateParam: String?
            if let comps = URLComponents(string: "http://x\(target)") {
                for item in comps.queryItems ?? [] {
                    if item.name == "code" { code = item.value }
                    if item.name == "state" { stateParam = item.value }
                }
            }
            let ok = code != nil
            let page = ok
                ? "<html><body style=\"font-family:sans-serif\"><h2>Signed in to Teams Notifier</h2><p>You can close this tab and return to the app.</p></body></html>"
                : "<html><body style=\"font-family:sans-serif\"><h2>Sign-in failed</h2><p>No authorization code received. Return to the app and try again.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            self.state.withLock {
                guard !$0.done, let c = $0.continuation else { return }
                $0.done = true
                $0.continuation = nil
                if let code {
                    c.resume(returning: Result(code: code, state: stateParam))
                } else {
                    c.resume(throwing: Error.missingCode)
                }
            }
        }
    }
}

/// Tiny mutex wrapper (Sendable).
final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
