# ClawChat — product boundary

ClawChat is a **pocket personal agent machine** that runs on an Android phone.

- **Linux is the general-purpose hand.** An embedded Alpine Linux userland holds
  the workspace, scripts, packages, imported skills, and web fetch. Agent
  commands run in proot with `/root/workspace` as the default directory.
- **Android is the private senses and actuators.** Calendar, SMS, contacts,
  alarms, share, navigation, and opening apps run through Android APIs, not
  through Linux shims.
- **Chat is the remote control**, not a third world. It drives both sides and
  asks for consent.
- It is **not** Cursor, not a resident system assistant, and not a pure Termux
  clone.

One-line filter for every feature:

> General-purpose work runs in Linux. Private phone data and phone actions run
> through Android APIs. Chat drives both.

## The two runtimes

| Surface | Job | Status |
| --- | --- | --- |
| Chat | Drive tools, show progress, ask for consent, recover interrupted work | current |
| Alpine / proot | Workspace, scripts, packages, imported skills, optional MCP hosts | current |
| Android APIs | Read calendar / SMS / contacts; local actions; gated outbound send | current |
| Terminal | First-class view of the Linux machine | current |
| Remote Agent | The bigger machine for long / always-on work | current |

## Tool surface

- `phone_read` — `listCalendarEvents`, `listSms`, `getSms`, `listContacts`.
  Read access is requested from Android at first use of that data. Results are
  bounded (window, limit caps, redacted calendar descriptions) and treated as
  untrusted input.
- `phone_act` — alarm, open URL, dialer, share, maps, compose email, camera,
  calendar UI. `insertCalendarEvent` still asks before writing.
- `phone_send` — `callPhone`, `sendSms`. Registered but **disabled** until the
  matching outbound setting is on; read access never implies send access.
- `phone_intent` — legacy mega-tool kept for one version as a hidden
  compatibility alias. It is not advertised to the model.

## Non-goals

- No mobile IDE: no LSP, repo index, code completion, or IDE chrome.
- No resident system assistant: no boot-start model run, notification listener,
  accessibility takeover, or silent outbound send.
- No cloud agent with a phone skin: local state stays authoritative; there is no
  mandatory account and no hosted control plane.
- No required account, cloud backup/sync, remote policy authority, or
  ClawChat-operated telemetry / analytics / crash pipeline.
- No engineering-coding product.
- No return to OpenClaw / Ubuntu / Node gateway as the on-device runtime.

## Privacy

- ClawChat operates **no** server for prompts, tool I/O, SMS/calendar bodies,
  secrets, or receipts.
- **User-configured model providers are an explicit send.** When the user has
  configured Claude / OpenAI-compatible / DeepSeek / etc., the selected
  conversation turn, tool schemas, and tool results — including bounded
  phone-read payloads — leave the device to that provider. This matches the
  privacy policy and the in-app explanation shown at first SMS read.
- Diagnostics exports stay local, metadata-oriented, and never automatic.

## Permission ownership

Every manifest permission has a written owner scenario:

| Permission | Owner scenario |
| --- | --- |
| `READ_CALENDAR` / `WRITE_CALENDAR` | `phone_read.listCalendarEvents`, `phone_act.insertCalendarEvent` / `addCalendarEventIntent`; requested at first use |
| `READ_CONTACTS` | `phone_read.listContacts`; requested at first use, never written |
| `READ_SMS` | `phone_read.listSms` / `getSms`; requested at first use. No `RECEIVE_SMS`, no broadcast watcher, no background read |
| `CALL_PHONE` / `SEND_SMS` | `phone_send`; unused until the matching outbound setting is on **and** the OS permission is granted |
| `RECEIVE_BOOT_COMPLETED` | **Retained.** The persisted cleanup job (`CommandCleanupCoordinator.kt` `.setPersisted(true)` on `CommandCleanupJobService`) needs it to survive reboot. It must never start a model or tool run. Not paired with `MANAGE_EXTERNAL_STORAGE` |
| `MANAGE_EXTERNAL_STORAGE` | **Retained for now.** This version does not prove that no user-initiated maintenance flow still uses it; removing it without that proof could break a supported flow. It is not a product default and agent bash still does not mount `/storage`; user-picked files go through SAF |
| `SYSTEM_ALERT_WINDOW` | Optional overlay; never requested during onboarding (I6) |
| `FOREGROUND_SERVICE_SPECIAL_USE` | User-started agent run only |
| `REQUEST_INSTALL_PACKAGES` | Sideload update flow |

Distribution for the next two versions is **APK / sideload**. Play Store is not
a goal for 2.9–2.10.

## Authorization posture

Existing `ToolPolicy`, skill capability policy, and per-call approval remain the
only execution authority. New phone tools, untrusted-data denies, and
background recovery compose with them in this order:

1. Fresh `operationId`, never recycled.
2. Canonicalize and bounds-check without executing.
3. Global hard deny.
4. Skill capability deny.
5. Untrusted-data deny (tainted destinations).
6. Approval: Ask / Auto Allow only where shared policy permits.
7. Execute; persist a terminal receipt before any terminal UI claim.

**Untrusted data.** SMS, calendar, contact, fetched web, and MCP text is tagged
untrusted and may not, by itself, drive `phone_send`, the local-handoff
`phone_act` actions, or `curl`/`wget`/`nc` to a tainted destination. Web→web
follow shows an Ask card with the exact URL.

## Linux runtime health (2.10.0)

The Alpine userland is the general-purpose hand, so the product must show
whether it is healthy without opening a raw terminal, and must be honest when a
command did not finish.

- **System Health** reports the disk used by the rootfs and its
  `/root/workspace`, the guest `resolv.conf` DNS status, and the last command
  state (**running** / **exited** / **unknown**). The checks read local state
  only: no proot command, no shared-storage mount, no telemetry, no score. A
  check that cannot run stays **unknown**; it is never shown as ready.
- **Command lifecycle** in the chat tool card is `started`, `running`,
  `completed`, `cancelled`, or `interrupted-unknown`. If Android kills the app
  mid-command, the card says the command did not finish and the command is
  **not** retried silently.
- **Workspace boundary.** Agent bash does not bind `/storage` or `/sdcard`; the
  regression tests pin both the Dart argument and the native flag builder.
  Whole-disk access is never re-enabled for agent commands.
- **Personal-script baseline.** The supported packages are the Alpine
  minirootfs plus `busybox`, `python3`, `git`, `curl`, and `jq`. There is no
  Node, no language server, and no second runtime manager on device.
- **No durable machine process.** This version introduces no always-on proot
  daemon, MCP supervisor, or additional foreground-service owner. Commands are
  user-started and tied to an agent run or a one-shot terminal/bash.
