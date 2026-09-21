import Foundation

/// Minimal JWT payload decode (no signature verification). Used to read the
/// owner's oid/upn/name claims out of the AAD access token.
public enum JWT {
    public struct Claims: @unchecked Sendable {
        /// Decoded JSON payload.
        public let raw: [String: Any]

        public var oid: String? { raw["oid"] as? String }
        public var upn: String? { raw["upn"] as? String ?? raw["preferred_username"] as? String }
        public var name: String? { raw["name"] as? String }
        /// Expiry epoch seconds, when present.
        public var exp: Int? {
            if let v = raw["exp"] as? Int { return v }
            if let v = raw["exp"] as? Double { return Int(v) }
            return nil
        }
    }

    public enum Error: Swift.Error, Sendable {
        case malformed
    }

    public static func decode(_ token: String) throws -> Claims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw Error.malformed }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - b64.count % 4) % 4
        b64 += String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Error.malformed }
        return Claims(raw: obj)
    }
}
