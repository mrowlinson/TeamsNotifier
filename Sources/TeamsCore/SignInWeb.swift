import Foundation

/// In-app device-code sign-in, pure half: start-URL choice, terminal failure
/// copy, notification identity, and the bundled offline demo stub. No AppKit,
/// no networking here; SignInWindowController (AppKit) renders these and App
/// owns the flow (challenge in, poll outcome out).
public enum SignInWeb {
    /// Page the sign-in webview loads: the code-prefilled complete URI when
    /// the server sent one, else the bare verification URI (owner types the
    /// shown code by hand).
    public static func startURL(challenge: DeviceCodeFlow.Challenge) -> String {
        if let complete = challenge.verificationURIComplete, !complete.isEmpty {
            return complete
        }
        return challenge.verificationURI
    }

    /// Code shown by the offline demo stub. Shaped like a real device code
    /// but unmistakably fake, so nobody types it into a live page.
    public static let demoUserCode = "DEMO-0000"

    /// Bundled offline stub mimicking the device-confirm layout: DEMO banner,
    /// code box, disabled Continue. Fully local: inline CSS, no links, no
    /// scripts, no external resources — safe to load with a nil base URL.
    public static func demoHTML(userCode: String = demoUserCode) -> String {
        let code = ReplyPayload.escape(userCode)
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Teams sign-in (DEMO)</title>
        <style>
        body { font-family: -apple-system, sans-serif; margin: 0; background: #f3f2f1; color: #201f1e; }
        .demo-banner { background: #ca5010; color: #fff; text-align: center;
          font-weight: bold; padding: 10px; letter-spacing: 1px; }
        .card { max-width: 340px; margin: 36px auto; background: #fff;
          border: 1px solid #edebe9; border-radius: 4px; padding: 28px; }
        h1 { font-size: 20px; font-weight: 600; margin: 0 0 12px; }
        p { font-size: 13px; line-height: 1.5; }
        .code { font-size: 26px; font-weight: bold; letter-spacing: 2px;
          text-align: center; border: 1px solid #8a8886; border-radius: 4px;
          padding: 12px; margin: 16px 0; }
        button { width: 100%; padding: 10px; font-size: 14px;
          background: #ebebeb; color: #8a8886; border: 1px solid #c8c6c4;
          border-radius: 4px; }
        .hint { color: #605e5c; font-size: 12px; }
        </style>
        </head>
        <body>
        <div class="demo-banner">DEMO — OFFLINE STUB, NO NETWORK</div>
        <div class="card">
        <h1>Teams sign-in (DEMO)</h1>
        <p>A sign-in was requested. Enter this code on the device-confirm page to continue:</p>
        <div class="code">\(code)</div>
        <p><button type="button" disabled>Continue (disabled in DEMO)</button></p>
        <p class="hint">DEMO only: this page is bundled with TeamsNotifier. No credentials leave this window, no network is used.</p>
        </div>
        </body>
        </html>
        """
    }
}

/// Terminal device-poll failures that land inline in the sign-in window (with
/// Retry + Open-in-browser), mirroring AuthManager.AuthError denied/expired.
public enum SignInFailure: Sendable {
    case denied
    case expired

    /// Inline window copy: what happened + the fix (Retry fetches a fresh code).
    public var message: String {
        switch self {
        case .denied:
            "Sign-in denied — the request was declined. Retry for a fresh code."
        case .expired:
            "Sign-in code expired before approval. Retry for a fresh code."
        }
    }
}

/// Notification identity for the sign-in challenge banner. Tapping it opens
/// (or reopens) the sign-in window instead of copying the body; message
/// banners keep copy-body + Reply/Open-chat untouched.
public enum SignInInfo {
    public static let categoryID = "TN_SIGNIN"
    public static let markerKey = "TNSignIn"
    /// Fixed id: a fresh challenge replaces the stale code banner, so an old
    /// (now invalid) code never lingers in Notification Center.
    public static let notificationID = "TN-signin"

    public static func userInfo() -> [String: String] {
        [markerKey: "1"]
    }

    /// Category match, with the userInfo marker as fallback.
    public static func isSignIn(category: String, userInfo: [AnyHashable: Any]) -> Bool {
        category == categoryID || (userInfo[markerKey] as? String == "1")
    }
}
