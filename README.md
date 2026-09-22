# TeamsNotifier

Menu-bar-only macOS app that posts native notifications for Teams chat
messages. No browser, no WebView, no OCR: user-delegated auth, realtime
over the trouter websocket (same channel the official client uses), chat
names via chat REST.

Why: the Teams desktop client is heavy and its notifications are
unreliable; this is a 652KB single binary idling at ~12MB footprint.

## Status

Beta. Parsers, filter, framing, auth plumbing, device-code flow, and
notifications are built and unit-tested (282 tests green). It signs in
against real work tenants today, but it rides undocumented Teams APIs
that Microsoft can change without notice; failures are loud (see
Limits). If something breaks, a log excerpt plus the fault line is
usually enough to diagnose.

## Screenshots

<!-- TODO: capture on a clean install and drop under docs/. -->
<!-- ![Menu bar status](docs/menu.png) -->
<!-- ![Notification banner with inline Reply](docs/notification.png) -->
<!-- ![Rules editor](docs/rules.png) -->
<!-- ![Schedule editor](docs/schedule.png) -->

Placeholders until captures land: menu-bar `TN` status (`connected`,
`Muted · schedule`, …), a notification banner with inline Reply,
the rules editor (goal picker + readable rows), the schedule editor
(weekly mute windows table).

## Setup

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
6. Optional config `~/.config/teamsnotifier/config.json` (tolerant
   decode: any missing key falls back to its default):
   ```json
   {"owner":{"displayName":"Alex Rivera","upn":"alex@company.com","mri":""}}
   ```
   `upn` enables a wrong-account warning. `mri` is auto-learned from the
   sign-in token when empty (preferred mention signal). Rules and the
   mute schedule live in the same file but are managed through the
   GUI (menu `Edit rules…` / `Edit schedule…`).
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

## Fresh-install behavior

A fresh install notifies for everything and mutes nothing:

- Blank rules list: every message notifies (own messages, edits,
  typing indicators included — the list decides what to quiet).
- Empty mute schedule: never muted by schedule.
- Noisy-chat matching off (no chat text configured).
- Owner identity empty until sign-in learns the MRI/UPN from the
  token (display name stays empty unless set via config or `--owner`;
  mention matching falls back to IDs only).

To quiet down: menu `Edit rules…` → Add → "Quiet down noisy chats"
(starter text `Watercooler` — replace with part of the chat name),
and `Edit schedule…` → Add windows such as weeknights + weekends.
Upgrading a config written before the public release? Its exact
effective values (schedule, rules, fills) migrate into the file on
first load, automatically.

## Knobs

- Noisy chats (default off): chats whose display name contains the
  configured text (case-insensitive) notify ONLY on your mention (MRI
  match preferred, display-name fallback) or channel/Everyone mention.
  All other chats always notify. Empty text disables the rule.
- `notifyTypes`: messagetype heads that notify (`Text`, `RichText`).
  Typing indicators, member-join activity, calls never notify.
- `notifyOnEdit` (default false): also notify on MessageUpdate edits.
- `skipOwnMessages` (default true).
- Notify rules, edited in the GUI (menu `Edit rules…`: list, add,
  remove, per-rule on/off, persisted to the config file): the extensible
  store behind the filters above — `skip-my-own-messages`,
  `only-these-message-types` (value e.g. `Text, RichText`),
  `skip-edited-messages`, `noisy-chats-mention-only` (value = chat-name
  text), `noisy-chats-channel-mentions`, `my-name-as-backup`,
  `always-notify-keywords` / `never-notify-keywords` (comma- or
  line-separated words; block beats allow; both yield to mute).
  Pre-rename ids (`skip-own`, `allow-types`, `skip-edits`, `loud-chat`)
  still load (mapped on decode). Fresh installs keep a blank list
  (everything notifies); unknown kinds round-trip unenforced.
- Scheduled mute, edited in the GUI (menu `Edit schedule…`: list, add,
  edit, remove entries, per-entry on/off switch, persisted to the config
  file): `muteWindows: [{days:[2,3,4,5,6],start:"16:40",end:"24:00"},
  {days:[2,3,4,5,6],start:"00:00",end:"07:50"},
  {days:[1,7],start:"00:00",end:"24:00"}]` (days = Calendar weekday,
  Sun=1; each entry also takes `enabled`), `scheduleTZ` (default
  `America/New_York`). Fresh installs start with an EMPTY schedule
  (never muted); configs that predate stored schedules migrate the
  legacy entries (muted Mon–Fri 00:00–07:50 + 16:40–24:00 ET + all day
  Sat/Sun) to the file on first load. Empty `muteWindows` disables
  scheduled mute. A manual Mute-toggle during a window holds until
  the next schedule boundary, then the schedule resumes; toggles are
  memory-only (fresh launches follow the schedule). Menu status shows the
  reason (`Muted · schedule`, `Unmuted · manual until 4:40 PM ET`, ...).

## History

Every notified message is appended to
`~/Library/Application Support/TeamsNotifier/history.jsonl` (one JSON
object per line: `timestamp`, `sender`, `chat`, `threadID`, `text`).
Menu `Show history` opens it in the default viewer. Notified only:
muted and filter-suppressed messages (noisy-chat no-mention, own/type/
edit skips) are never recorded. Retention: newest 10k entries + 30 days,
pruned on launch and daily. NOTE: plaintext on disk — anyone with file
access can read past message text.

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
  same as the referenced OSS clients. Your call.
- Channel vs group-chat threading: notification titles use the chat
  topic when Teams provides one, else member name, else thread id.
- Replies post a plain message to the thread (not a threaded quote under
  the triggering message). 1:1 + group chats proven by refs; channel
  threads use the same endpoint (no channel-specific send in any ref)
  but are live-untested — a rejection surfaces as "Reply failed".
- Direct-binary launch showed a notification-auth refusal in testing;
  install to /Applications and launch via Finder/`open` before judging.

## License

MIT — see [LICENSE](LICENSE).
