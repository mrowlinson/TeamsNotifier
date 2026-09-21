# TeamsNotifier

Menu-bar-only macOS app that posts native notifications for Teams chat
messages. No browser, no WebView, no OCR: user-delegated auth, realtime
over the trouter websocket (same channel the official client uses), chat
names via chat REST.

Why: the Teams desktop client is heavy and its notifications are
unreliable; this is a 652KB single binary idling at ~12MB footprint.

## Status

Parsers, filter, framing, auth plumbing, device-code flow, and
notifications are built and unit-tested (83 tests green). Live auth +
realtime against the owner's
work tenant is **not yet validated** — owner runs Setup below and reports
back. Internal Teams APIs can drift; failures are loud (see Limits).

## Setup (owner steps)

1. Build + install:
   `Scripts/package.sh --install`
2. Launch `/Applications/TeamsNotifier.app` (`TN` appears in menu bar).
3. Sign-in is a device code (no redirect URI to register):
   the app copies a code like `XXXX-XXXX` to the clipboard, opens
   `microsoft.com/devicelogin` in the default browser, and posts a
   notification with the code + URL. Paste/type the code, sign in with
   the **work** account (interactive + MFA/CA fine), approve. Menu shows
   `waiting for sign-in…`, then `connected`. No tokens touch disk except
   the refresh token (Keychain, `com.teamsnotifier.tokens`).
4. Allow notifications when prompted. For sticky banners: System Settings
   > Notifications > TeamsNotifier > Banner style **Alerts**.
5. Menu `TN` should show `connected`. Send yourself a Teams message from
   another device, or have someone message you; a notification appears.
   Click a notification copies its body to clipboard (no GUI to open).
   Long-press/click Reply in the banner to answer inline (one HTTPS POST
   per reply, zero idle cost). Success is silent (debug log); failure
   posts "Reply failed: <reason>". Replies work while muted (mute gates
   inbound notifications only).
6. Optional config `~/.config/teamsnotifier/config.json`:
   ```json
   {"owner":{"displayName":"Michael Rowlinson","upn":"you@company.com","mri":""},
    "loudSubstring":"BTAC","notifyOnEdit":false,"skipOwnMessages":true,
    "notifyTypes":["Text","RichText"]}
   ```
   `upn` enables a wrong-account warning. `mri` is auto-learned from the
   sign-in token when empty (preferred mention signal).
7. Optional start-at-login: `Scripts/install-launch-agent.sh`
   (logs to `/tmp/teamsnotifier.log`).

Fallback: relaunch with `--auth loopback` for the older system-browser
flow (RFC 8252 loopback redirect, root path). If that fails, the app
offers a manual flow: it opens the sign-in page, you paste the redirect
URL back (`http://127.0.0.1:8765/?code=...`, connection-refused page is
expected — the `?code=` in the address bar is what matters).

Useful flags: `--verbose` (debug to stderr), `--notify-test`,
`--sign-in`, `--sign-out`, `--offline` (menu only, no network),
`--auth device|loopback` (default device), `--help`.

## Knobs

- `loudSubstring` (default `BTAC`): chats whose display name contains it
  (case-insensitive) notify ONLY on owner mention (MRI match preferred,
  display-name fallback) or channel/Everyone mention. All other chats
  always notify. Empty string disables the rule.
- `notifyTypes`: messagetype heads that notify (`Text`, `RichText`).
  Typing indicators, member-join activity, calls never notify.
- `notifyOnEdit` (default false): also notify on MessageUpdate edits.
- `skipOwnMessages` (default true).
- Scheduled mute (default: Mon–Fri 07:50–16:40 ET + all day Sat/Sun):
  `muteWindows: [{days:[2,3,4,5,6],start:"07:50",end:"16:40"},
  {days:[1,7],start:"00:00",end:"24:00"}]` (days = Calendar weekday,
  Sun=1), `scheduleTZ` (default `America/New_York`). Empty `muteWindows`
  disables scheduled mute. A manual Mute-toggle during a window holds until
  the next schedule boundary, then the schedule resumes; toggles are
  memory-only (fresh launches follow the schedule). Menu status shows the
  reason (`Muted · schedule`, `Unmuted · manual until 4:40 PM ET`, ...).

## How it works

- Auth: RFC 8628 device code against AAD `organizations` (Teams desktop
  public client `1fec8e78-...`, scope
  `https://api.spaces.skype.com/.default openid profile offline_access`,
  no redirect URI) -> token endpoint poll (interval + slow_down backoff)
  -> `POST teams.microsoft.com/api/authsvc/v1.0/authz` exchanges AAD
  token for skype token + regionGtms. Fallback `--auth loopback`: system
  browser + PKCE S256 + RFC 8252 loopback redirect (root path, listener
  started before the port is read). Owner MRI/UPN learned from token
  claims. Refresh token in Keychain; expiry posts "sign-in needed" and
  reopens sign-in. No app registration, no admin consent. DISCLOSURE:
  reuses Microsoft's public Teams client ID (same pattern as
  purple-teams, ost). ASWebAuthenticationSession was specced but cannot
  work here (needs a custom scheme registered on the OAuth client, which
  we don't own).
- Realtime: `POST go.trouter.teams.microsoft.com/v4/a` ->
  socket.io session GET -> `URLSessionWebSocketTask` -> `user.authenticate`
  + `user.activity` -> registrar (NextGenCalling, SkypeSpacesWeb,
  TeamsCDLWebWorker) -> ping every 30s, ack every `3:::` frame, reconnect
  with backoff, re-register on `trouter.message_loss`.
- Messages: `/messaging` frames only, `NewMessage` resourceType, gzip/cp/gp
  decode, dedup ring (10), HTML stripped to plain text, mentions from
  `properties.mentions` (content-span fallback), chat names from
  `threadtopic` or `GET {chatService}/v1/users/ME/conversations/{id}`.

Protocol sources: EionRobb/purple-teams, eisbaw/ost, agent-messenger
trouter (PR #281), weirdapps/teams-access, roshank8s/teams-api,
dinhhant9/teams_lite. See `Sources/TeamsCore/Constants.swift` + per-file
headers for exact endpoint/scope provenance.

## Measured footprint (release, idle, connected-path untested)

- Binary 652KB, zero third-party deps (SwiftPM, AppKit/Foundation only).
- Idle: RSS ~54MB, `footprint` phys ~12MB, CPU 0.0% (`--offline`, 10s+).
- Target was <60MB / ~0 CPU: met on both RSS and footprint.

## Limits / risks

- Internal, undocumented Teams APIs: Microsoft can change endpoints,
  headers, token audiences, or block the reused client ID at any time.
  Failures are loud: `FAULT` lines in stderr/log, menu status shows
  retry state, auth death posts a notification and reopens sign-in.
- ToS gray area: read-only access to your own data via internal APIs,
  same as the referenced OSS clients. Owner's call.
- Live path (sign-in, trouter events, chat REST, notification delivery
  from installed bundle) validated by owner, not by the agent.
- Direct-binary launch showed a notification-auth refusal in testing;
  install to /Applications and launch via Finder/`open` before judging.
- Channel vs group-chat threading: notification titles use the chat
  topic when Teams provides one, else member name, else thread id.
- Replies post a plain message to the thread (not a threaded quote under
  the triggering message). 1:1 + group chats proven by refs; channel
  threads use the same endpoint (no channel-specific send in any ref)
  but are live-untested — a rejection surfaces as "Reply failed".
