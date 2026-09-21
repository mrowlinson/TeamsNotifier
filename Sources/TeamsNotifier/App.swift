import AppKit
import Foundation
import TeamsCore

// MARK: - CLI flags

struct Flags {
    var configPath: String = Config.defaultPath
    var ownerName: String?
    var ownerUPN: String?
    var ownerMRI: String?
    var loudSubstring: String?
    var verbose = false
    var notifyTest = false
    var signIn = false
    var signOut = false
    var offline = false
    var authMethod: AuthManager.AuthMethod = .device
    var help = false

    static func parse(_ args: [String]) -> Flags {
        var f = Flags()
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--config": i += 1; if i < args.count { f.configPath = args[i] }
            case "--owner": i += 1; if i < args.count { f.ownerName = args[i] }
            case "--upn": i += 1; if i < args.count { f.ownerUPN = args[i] }
            case "--mri": i += 1; if i < args.count { f.ownerMRI = args[i] }
            case "--loud": i += 1; if i < args.count { f.loudSubstring = args[i] }
            case "--verbose", "-v": f.verbose = true
            case "--notify-test": f.notifyTest = true
            case "--sign-in": f.signIn = true
            case "--sign-out": f.signOut = true
            case "--offline": f.offline = true
            case "--auth":
                i += 1
                if i < args.count, let m = AuthManager.AuthMethod(rawValue: args[i]) {
                    f.authMethod = m
                } else {
                    fputs("unknown --auth value (want device|loopback)\n", stderr)
                }
            case "--help", "-h": f.help = true
            default: fputs("unknown flag: \(args[i])\n", stderr)
            }
            i += 1
        }
        return f
    }

    static let usage = """
    TeamsNotifier — menu-bar Teams chat notifier (native, no browser).

    Flags:
      --config PATH   config file (default ~/.config/teamsnotifier/config.json)
      --owner NAME    owner display name (default: Michael Rowlinson)
      --upn UPN       owner work UPN (expected, matched against token)
      --mri MRI       owner Skype MRI 8:orgid:... (auto-learned if empty)
      --loud SUBSTR   loud-chat substring (default BTAC)
      --verbose, -v   debug logging to stderr
      --notify-test   post a test notification and keep running
      --sign-in       force interactive sign-in on launch
      --sign-out      clear Keychain tokens and exit
      --offline       menu bar only, no auth or connection (smoke test)
      --auth M        sign-in transport: device (default) or loopback
      --help, -h      this text
    """
}

// MARK: - App

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// No nib wires the delegate, so do it in main (NSApp.delegate is weak).
    private static var keeper: AppDelegate?

    static func main() {
        let delegate = AppDelegate()
        keeper = delegate
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }

    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var flags = Flags()
    private var config = Config.default
    private var auth = AuthManager()
    private var api: TeamsAPI?
    private var trouter: TrouterClient?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar only, no dock icon
        flags = Flags.parse(CommandLine.arguments)
        Log.verbose = flags.verbose

        if flags.help {
            print(Flags.usage)
            NSApp.terminate(nil)
            return
        }
        if flags.signOut {
            Task {
                await auth.signOut()
                Log.info("signed out, Keychain cleared")
                NSApp.terminate(nil)
            }
            return
        }

        do {
            config = try Config.load(from: flags.configPath)
        } catch {
            Log.fault("config load failed (\(flags.configPath)): \(error), using defaults")
            config = .default
        }
        if let v = flags.ownerName { config.owner.displayName = v }
        if let v = flags.ownerUPN { config.owner.upn = v }
        if let v = flags.ownerMRI { config.owner.mri = v }
        if let v = flags.loudSubstring { config.loudSubstring = v }

        Notifier.shared.setup()
        setupMenu(status: "starting…")

        Task {
            await startup()
        }
    }

    // MARK: Startup

    private func startup() async {
        let granted = await Notifier.shared.requestAuthorization()
        let authStatus = await Notifier.shared.authorizationStatus()
        Log.info("notification authorization: \(NotificationAuth.label(rawValue: authStatus.rawValue))")
        if NotificationAuth.isBlocked(rawValue: authStatus.rawValue) {
            setStatus("notifications blocked — enable in Settings")
            Log.fault("notifications blocked; enable in System Settings > Notifications")
        } else if !granted {
            Log.fault("notifications not granted; enable in System Settings > Notifications")
        }
        if flags.notifyTest {
            Notifier.shared.post(title: "Test sender in Test chat", body: "Hello from TeamsNotifier. Click copies this text.")
        }

        await auth.setNeedsSignInHandler { [weak self] reason in
            Task { await self?.handleNeedsSignIn(reason: reason) }
        }

        if flags.offline {
            setStatus("offline (smoke test)")
            Log.info("offline mode: no auth, no connection")
            return
        }
        let authed = await auth.hasRefreshToken
        if flags.signIn || !authed {
            await interactiveSignIn()
        }
        guard await auth.hasRefreshToken else {
            setStatus("not signed in")
            Log.fault("no refresh token; use menu Sign in")
            return
        }

        // UPN sanity: warn when token owner differs from configured UPN.
        await checkUPN()

        api = TeamsAPI(auth: auth)
        let cfg = config
        let authRef = auth
        let apiRef = api!
        trouter = TrouterClient(
            auth: authRef,
            onMessage: { [weak self] message, isEdit in
                await self?.handleMessage(message, isEdit: isEdit, api: apiRef, config: cfg)
            },
            onState: { [weak self] state in
                await MainActor.run { self?.reflect(state: state) }
            }
        )
        await trouter?.run()
    }

    private func checkUPN() async {
        let store = TokenStore()
        let learned = store.readOwnerUPN()
        let want = config.owner.upn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !want.isEmpty, let learned, !learned.isEmpty,
              learned.caseInsensitiveCompare(want) != .orderedSame
        else { return }
        let msg = "signed in as \(learned), config expects \(want)"
        Log.fault(msg)
        Notifier.shared.postSystem(title: "TeamsNotifier: wrong account?", body: msg)
    }

    private func handleNeedsSignIn(reason: String) async {
        Notifier.shared.postSystem(
            title: "TeamsNotifier: sign-in needed",
            body: "Teams session expired (\(reason.prefix(120))). Opening sign-in…"
        )
        await MainActor.run { self.setStatus("sign-in needed") }
        await interactiveSignIn()
    }

    // MARK: Messages

    private func handleMessage(_ m: EventMessage.Message, isEdit: Bool, api: TeamsAPI, config: Config) async {
        let ownerMRI = await auth.ownerMRI(configured: config.owner.mri)
        let chatName = await api.chatDisplayName(chatID: m.chatID, threadTopic: m.threadTopic)
        let decision = ChatFilter.decide(message: m, isEdit: isEdit, chatDisplayName: chatName, ownerMRI: ownerMRI, config: config)
        switch decision {
        case .skip(let reason):
            Log.debug("skip [\(reason)] \(m.senderName) in \(chatName)")
        case .notify(let reason):
            let title: String
            if chatName.isEmpty || chatName == m.chatID {
                title = m.senderName.isEmpty ? "Teams message" : m.senderName
            } else {
                title = m.senderName.isEmpty ? chatName : "\(m.senderName) in \(chatName)"
            }
            Log.info("notify [\(reason)] \(title)")
            Notifier.shared.post(title: title, body: m.plainText, id: m.messageID.isEmpty ? nil : m.messageID)
        }
    }

    // MARK: Sign-in UI

    @MainActor
    private func interactiveSignIn() async {
        let method = flags.authMethod
        if method == .device {
            await auth.setDeviceCodeHandler { [weak self] challenge in
                Task { await self?.handleDeviceChallenge(challenge) }
            }
            setStatus("requesting sign-in code…")
        } else {
            setStatus("signing in… (browser)")
        }
        do {
            try await auth.signInInteractive(method: method)
            setStatus("signed in")
            Log.info("interactive sign-in ok (\(method))")
            if method == .device {
                Notifier.shared.postSystem(
                    title: "TeamsNotifier: connected",
                    body: "Sign-in complete. Watching for Teams messages."
                )
            }
        } catch AuthManager.AuthError.cancelled {
            setStatus("sign-in cancelled")
            Log.fault("sign-in timed out or was cancelled; menu Sign in to retry")
        } catch AuthManager.AuthError.denied {
            setStatus("sign-in denied — Sign in to retry")
            Log.fault("device-code request declined; menu Sign in to retry")
            Notifier.shared.postSystem(
                title: "TeamsNotifier: sign-in denied",
                body: "The request was declined. Use menu Sign in to retry."
            )
        } catch AuthManager.AuthError.expired {
            setStatus("sign-in expired — Sign in to retry")
            Log.fault("device code expired before approval; menu Sign in to retry")
            Notifier.shared.postSystem(
                title: "TeamsNotifier: sign-in code expired",
                body: "The code timed out. Use menu Sign in to get a fresh one."
            )
        } catch {
            setStatus("sign-in failed")
            Log.fault("sign-in failed: \(error)")
            if method == .loopback {
                offerManualSignIn()
            } else {
                Notifier.shared.postSystem(
                    title: "TeamsNotifier: sign-in failed",
                    body: "\(error). Menu Sign in to retry, or relaunch with --auth loopback."
                )
            }
        }
    }

    /// Device-code UX: code to clipboard, verification page in the default
    /// browser, notification carrying code + URL. Menu shows waiting state.
    private func handleDeviceChallenge(_ c: DeviceCodeFlow.Challenge) async {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(c.userCode, forType: .string)
        let openURL = c.verificationURIComplete ?? c.verificationURI
        if let url = URL(string: openURL) {
            NSWorkspace.shared.open(url)
        }
        setStatus("waiting for sign-in…")
        Notifier.shared.postSystem(
            title: "Teams sign-in: enter code \(c.userCode)",
            body: "Code \(c.userCode) copied to clipboard — enter it at \(c.verificationURI)"
        )
        Log.info("device challenge posted, waiting for owner approval")
    }

    /// Paste-code fallback window (allowed: sign-in is the one window case).
    @MainActor
    private func offerManualSignIn() {
        let alert = NSAlert()
        alert.messageText = "Teams sign-in failed in the browser flow"
        alert.informativeText = "Use the manual flow: the app opens the sign-in page, you paste back the redirect URL (it shows connection-refused; the ?code= in the address bar is what matters)."
        alert.addButton(withTitle: "Open manual sign-in")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let flow = await auth.authorizeURLForManualFlow()
            await MainActor.run { NSWorkspace.shared.open(flow.url) }
            Log.info("manual authorize URL opened: \(flow.url)")
            guard let pasted = await MainActor.run(resultType: String?.self, body: self.promptForCode) else { return }
            do {
                try await auth.exchangeManualCode(pasted, verifier: flow.verifier, redirectURI: flow.redirectURI, state: flow.state)
                await MainActor.run { self.setStatus("signed in") }
            } catch {
                Log.fault("manual code exchange failed: \(error)")
            }
        }
    }

    @MainActor
    private func promptForCode() -> String? {
        let alert = NSAlert()
        alert.messageText = "Paste the redirect URL"
        alert.informativeText = "After signing in, copy the full address-bar URL (http://127.0.0.1:8765/?code=...) and paste it here."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    // MARK: Menu

    private func setupMenu(status: String) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "TN"
        item.button?.toolTip = "TeamsNotifier"
        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusMenuItem?.isEnabled = false
        menu.addItem(statusMenuItem!)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Sign in", action: #selector(menuSignIn), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Send test notification", action: #selector(menuTest), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(menuQuit), keyEquivalent: "q"))
        for i in menu.items { i.target = self }
        item.menu = menu
        statusItem = item
    }

    private func setStatus(_ s: String) {
        statusMenuItem?.title = s
        statusItem?.button?.toolTip = "TeamsNotifier: \(s)"
    }

    private func reflect(state: TrouterClient.State) {
        switch state {
        case .stopped: setStatus("stopped")
        case .connecting(let s): setStatus("connecting (\(s))…")
        case .connected: setStatus("connected")
        case .backoff(let s): setStatus("retry in \(s)s")
        }
    }

    @objc private func menuSignIn() {
        Task { await interactiveSignIn() }
    }

    @objc private func menuTest() {
        Notifier.shared.post(title: "Test sender in Test chat", body: "Hello from TeamsNotifier. Click copies this text.")
    }

    @objc private func menuQuit() {
        Task {
            await trouter?.stop()
            NSApp.terminate(nil)
        }
    }
}
