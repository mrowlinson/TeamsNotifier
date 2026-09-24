import AppKit
import Foundation
import TeamsCore
import WebKit

/// Device-code sign-in window: the Microsoft verification page in an in-app
/// webview (persistent default data store, so sessions/cookies survive
/// across challenges) with Open-in-browser fallback + Close. One window at
/// a time: re-show focuses and reloads. App auto-closes it on sign-in
/// success; denied/expired lands inline as message + Retry (fresh challenge)
/// + Open-in-browser. Menu-bar-only character kept: on-demand panel, closes
/// to nothing, no dock change.
@MainActor
final class SignInWindowController: NSWindowController {
    private static var shared: SignInWindowController?
    /// Last live challenge (+ its retry), kept across window close so a tap
    /// on the sign-in notification reopens the pending challenge. Cleared on
    /// success; the demo page never touches these.
    private static var lastChallenge: DeviceCodeFlow.Challenge?
    private static var lastRetry: (() -> Void)?

    static var isShowing: Bool { shared != nil }

    /// Show (or focus + reload) the window for a device challenge. `onRetry`
    /// must start a fresh challenge (App passes interactiveSignIn).
    static func show(challenge: DeviceCodeFlow.Challenge, onRetry: @escaping () -> Void) {
        lastChallenge = challenge
        lastRetry = onRetry
        if let existing = shared {
            existing.showChallenge(challenge, onRetry: onRetry)
            existing.focus()
            return
        }
        let wc = SignInWindowController()
        shared = wc
        wc.showChallenge(challenge, onRetry: onRetry)
        wc.focus()
    }

    /// Offline demo (--signin-demo): window on the bundled DEMO stub, no URL.
    static func showDemoPage() {
        if let existing = shared {
            existing.showDemo()
            existing.focus()
            return
        }
        let wc = SignInWindowController()
        shared = wc
        wc.showDemo()
        wc.focus()
    }

    /// Focus the open window, if any. Menu Sign in while a challenge shows.
    static func focus() {
        shared?.focus()
    }

    /// Sign-in notification tap: focus the open window, else reopen the last
    /// pending challenge (closed mid-poll). No-op once nothing is pending.
    static func focusOrRestore() {
        if shared != nil {
            focus()
            return
        }
        if let c = lastChallenge, let retry = lastRetry {
            show(challenge: c, onRetry: retry)
        }
    }

    /// Sign-in success: close the window, forget the challenge.
    static func closeOnSuccess() {
        lastChallenge = nil
        lastRetry = nil
        shared?.close()
        shared = nil
    }

    /// Denied/expired: inline message + Retry (fresh challenge) +
    /// Open-in-browser. Recreates the window when it was closed mid-poll.
    static func showFailure(_ kind: SignInFailure, onRetry: @escaping () -> Void) {
        lastRetry = onRetry
        if let existing = shared {
            existing.showFailureState(kind, onRetry: onRetry)
            existing.focus()
            return
        }
        let wc = SignInWindowController()
        shared = wc
        wc.showFailureState(kind, onRetry: onRetry)
        wc.focus()
    }

    // MARK: views

    private let infoLabel = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let webView: WKWebView
    private let openButton = NSButton(title: "Open in browser", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)

    /// URL for the Open-in-browser fallback (challenge start URL, else nil).
    private var fallbackURL: URL?
    private var onRetry: (() -> Void)?

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // persistent: sessions survive
        self.webView = WKWebView(frame: .zero, configuration: config)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        panel.title = "Teams sign-in"
        panel.center()
        panel.isReleasedWhenClosed = false
        // Plain NSPanel won't take key (no typing into the page); this one must.
        panel.becomesKeyOnlyIfNeeded = false
        super.init(window: panel)
        buildUI()
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        infoLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        infoLabel.textColor = .secondaryLabelColor

        messageLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        messageLabel.textColor = .systemRed

        // No intrinsic size: floor height + lowest hugging so it fills the stack.
        webView.setContentHuggingPriority(.init(1), for: .vertical)
        webView.setContentHuggingPriority(.init(1), for: .horizontal)
        webView.heightAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true

        openButton.target = self
        openButton.action = #selector(openClicked)
        retryButton.target = self
        retryButton.action = #selector(retryClicked)
        retryButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.keyEquivalent = "\u{1b}" // Esc closes

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [openButton, retryButton, spacer, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [infoLabel, webView, messageLabel, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        let g = content.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: g.topAnchor),
            stack.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: g.bottomAnchor),
        ])
    }

    private func focus() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: states

    private func showChallenge(_ c: DeviceCodeFlow.Challenge, onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        infoLabel.stringValue = "Enter code \(c.userCode) on the Microsoft page (copied to clipboard)."
        messageLabel.stringValue = ""
        messageLabel.isHidden = true
        retryButton.isHidden = true
        let start = SignInWeb.startURL(challenge: c)
        fallbackURL = URL(string: start)
        openButton.isEnabled = fallbackURL != nil
        if let url = fallbackURL {
            webView.load(URLRequest(url: url))
        }
    }

    private func showDemo() {
        onRetry = nil
        infoLabel.stringValue = "DEMO — offline stub, no network, nothing to approve."
        messageLabel.stringValue = ""
        messageLabel.isHidden = true
        retryButton.isHidden = true
        fallbackURL = nil
        openButton.isEnabled = false
        webView.loadHTMLString(SignInWeb.demoHTML(), baseURL: nil)
    }

    private func showFailureState(_ kind: SignInFailure, onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        messageLabel.textColor = .systemRed
        messageLabel.stringValue = kind.message
        messageLabel.isHidden = false
        retryButton.isHidden = false
        retryButton.isEnabled = true
        openButton.isEnabled = fallbackURL != nil
    }

    // MARK: actions

    @objc private func openClicked() {
        guard let url = fallbackURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func retryClicked() {
        retryButton.isEnabled = false
        messageLabel.stringValue = "Requesting a new code…"
        messageLabel.isHidden = false
        messageLabel.textColor = .secondaryLabelColor
        onRetry?()
    }

    @objc private func closeClicked() {
        close()
    }
}

// MARK: - close

extension SignInWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Drop the window but keep the pending challenge: a tap on the
        // sign-in notification reopens it (focusOrRestore).
        Self.shared = nil
    }
}
