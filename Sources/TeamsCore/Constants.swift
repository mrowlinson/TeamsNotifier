/// Protocol constants reverse-engineered from the Teams clients by others.
/// Sources: EionRobb/purple-teams (teams_login.c, teams_trouter.c, libteams.h),
/// eisbaw/ost (src/auth, src/trouter, src/api), agent-messenger trouter.ts
/// (PR #281), weirdapps/teams-access (chatsvc clients), roshank8s/teams-api.
///
/// AUTH DISCLOSURE: this app signs in with the public Teams desktop client ID
/// below, the same pattern purple-teams and ost use. No app registration, no
/// tenant admin consent. Tokens are user-delegated; the app only reads the
/// owner's own chats. Microsoft could revoke/block this client ID for
/// third-party use at any time; failure mode is loud (sign-in error).
public enum TeamsConstants {
    // MARK: - OAuth (work accounts, purple-teams work branch + ost work())

    /// Public client ID of the Teams desktop client. Reused, not owned.
    public static let workClientID = "1fec8e78-bce4-4aaf-ab1b-5451cc387264"

    public static let tenant = "organizations"
    public static let authorizeURL = "https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize"
    public static let tokenURL = "https://login.microsoftonline.com/organizations/oauth2/v2.0/token"
    /// RFC 8628 device authorization endpoint (primary sign-in; no redirect
    /// URI, so no reply-URL registration needed on the reused client).
    public static let deviceCodeURL = "https://login.microsoftonline.com/organizations/oauth2/v2.0/devicecode"

    /// Primary scope. The api.spaces.skype.com access token is exchanged for
    /// a skype token; its JWT claims (oid, name, preferred_username) also
    /// identify the owner. openid/profile/offline_access mirror purple-teams.
    public static let primaryScope = "https://api.spaces.skype.com/.default openid profile offline_access"

    /// Loopback redirect for native public clients (RFC 8252, fallback
    /// sign-in). Root path: the reused first-party client has no /callback
    /// registration (AADSTS50011), so use http://127.0.0.1:{port}/.
    public static let loopbackHost = "127.0.0.1"
    public static let loopbackPath = "/"

    // MARK: - Skype token exchange (ost skype.rs, purple-teams teams_login.c)

    public static let authzURLWork = "https://teams.microsoft.com/api/authsvc/v1.0/authz"

    // MARK: - Chat REST (ost client.rs / chat.rs)

    /// Fallback when regionGtms.chatService is missing from the authz response.
    public static let defaultChatService = "https://amer.ng.msg.teams.microsoft.com"
    public static let clientVersionHeader = "1416/1.0.0.2024050301"

    // MARK: - Trouter (purple-teams teams_trouter.c, agent-messenger trouter.ts)

    public static let trouterBootstrap = "https://go.trouter.teams.microsoft.com/v4/a"
    public static let registrarURLWork = "https://teams.microsoft.com/registrar/prod/V2/registrations"
    public static let trouterTTL = 86400
    public static let trouterTCCV = "2024.23.01.2"
    public static let clientInfoVersion = "49/25113001312"
    public static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0 Teams/24165.1410.2974.6689/49"
    public static let pingIntervalSeconds = 30

    public struct Registration: Sendable {
        public let appID: String
        public let templateKey: String
        public let pathSuffix: String
        /// Reuse the trouter endpoint id as registration id (messaging worker).
        public let reuseEndpointID: Bool
    }

    /// Order matters: messaging worker last (purple-teams comment).
    /// Template keys are the newest seen across refs (agent-messenger).
    public static let registrations: [Registration] = [
        Registration(appID: "NextGenCalling", templateKey: "DesktopNgc_2.5:SkypeNgc", pathSuffix: "NGCallManagerWin", reuseEndpointID: false),
        Registration(appID: "SkypeSpacesWeb", templateKey: "SkypeSpacesWeb_2.4", pathSuffix: "SkypeSpacesWeb", reuseEndpointID: false),
        Registration(appID: "TeamsCDLWebWorker", templateKey: "TeamsCDLWebWorker_2.6", pathSuffix: "", reuseEndpointID: true),
    ]

    /// Re-register spec on trouter.message_loss (purple-teams uses _1.9 here;
    /// agent-messenger reuses the same worker spec; use current worker spec).
    public static let messageLossResubscribe = Registration(
        appID: "TeamsCDLWebWorker", templateKey: "TeamsCDLWebWorker_2.6", pathSuffix: "", reuseEndpointID: true
    )
}
