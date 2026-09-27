# Changelog

## v2.15.0 — Local automation, memory visibility, workflow templates

- **计划执行（本地计划）** — 已批准的本地任务可以排下一次时间：一次性或每 15–1440 分钟，支持暂停 / 继续 / 删除、下次运行提示、失败次数与重试上限、最多 20 条执行历史。计划存储在 `clawchat_scheduled_tasks_v1`，只保存 `taskId` 与调度元数据（任务内容仍留在加密的后台任务存储）。**没有执行 API**：到期后计划只进入“等待确认”，实际运行仍走任务中心的人工确认与既有审批策略；一次性计划跑完即结束，需要新的时间才会再跑，间隔计划按计划时间推进而不补跑错过的次数。新建计划必须勾选“到期后需要我再次确认才会执行”。入口：任务中心 → 计划执行。
- **记忆可见性** — 记忆管理为每条事实标明 `用户确认（可信）` 或 `来自 <source>`，删除按钮改用 `forgetFact(text)`，使事实与其信任记录一起移除。新增“本轮记忆”（聊天命令面板）：显示**最近一次回复实际注入**的记忆快照与来源，因为是运行快照，事后改开关不会改写当时用了什么。每个会话可单独开关记忆（与全局值一致时清除覆盖、回到跟随全局，旧设置语义不变），全局开关、覆盖值与最终生效值分别显示。会话覆盖从 guest 可写的 `root/.clawchat_memory_sessions.json` 迁到加密应用私有存储（`clawchat.memory_session_modes.v1`，sha256 信封）：旧文件不再被读取、只被检测并退休，被 agent shell 改写的 `enabled` 不再生效；存储损坏（非 Map / schema 错误 / 校验和不符 / 读不到）按 **disabled 优先**，用户再次设置开关即重写合格式存储。信任标志存储同样收紧：合法 JSON 但顶层不是 Map、键或值类型不对、未知来源名都标记为整份加载失败，所有事实按不可信处理且不被静默修复。不可信事实仍进入 Untrusted memories 段落与运行期 taint 集合。
- **工作流模板** — 技能与扩展新增“工作流模板”：内置 2 个本地模板（每日工作总结：workspace 读写 + memory 读取；日程提醒草稿：手机日历读取 + workspace 写入）。安装前预览所需权限、是否联网、会接触的隐私数据、风险说明，以及安装会写入的 capability 清单；校验拒绝未知能力、超过 16 KiB 的正文，以及正文包含 `http(s)://` / `curl` / `wget` 的模板。模板正文在应用内编译（无 URL 字段、无远程下载），安装写入 `workspace/skills/<id>/SKILL.md` 与受控的 `skill.json`（声明 tools / filesystem / android / networkDomains / riskTier，并带 sha256 自校验摘要），上一份包文件保留为 `.rollback`。清单是唯一能力来源：`scanSkills` 按带清单技能读取且能力快照与预览一致，清单被改动即判无效；启用必须通过既有已安装技能同意流程记录 grant（否则 `setEnabled` 返回 `template_consent_required`），正文或清单变化后需重新同意；运行期未声明的工具被 `skill_tool_undeclared` 拒绝，文件读写仍是显式 `skill_filesystem_unenforceable` 拒绝，可按包回滚且回滚后保持禁用。

### Residual in 2.15.0

- 计划不会在应用未运行、被杀或重启后自动恢复执行，也没有系统闹钟 / WorkManager 触发；`due()` 只是本地查询，重启后仍需用户在任务中心确认。
- 模板只有“上一份包（正文 + 清单）”这一级回滚，没有版本仓库或签名。
- 从旧版本升级时，如果 guest 可写的 `root/.clawchat_memory_sessions.json` 仍存在，本次启动按 disabled 优先且不导入其内容；文件被退休后下一次启动回到全局设置，用户重新设置会话开关即可。
- 本路线没有原生 Android 代码改动，也是唯一没有设备验证的部分。

## v2.14.0 — Multi-destination backup

- **A backup run can write one config package to several local folders** — 数据管理 adds 多目标备份 beside the existing single-file 导出配置. The run stages the existing export package locally, writes it to each folder chosen through the existing file picker, shows per-destination progress, and can be cancelled; each destination is recorded success or failure, secrets stay redacted unless the user confirms the existing plaintext option, and the staged local package is deleted only after every selected destination succeeds (a failed or cancelled run leaves it for a retry). Restore still uses the existing import preview.
- **Provider routing and bounded summary** — a selected model group now resolves only members whose provider profile has a usable credential (an API key, or an explicitly configured keyless local / self-hosted base URL) and fails with the existing missing-key message when none remain, instead of silently falling through to an unrelated profile. Manual context summary is bounded to 30 seconds and 2 model calls, reports started / summarizing / done / failed, and a cancel or timeout keeps the previous summary.
- **Long pastes become chips, hardware shortcuts live at the shell** — a paste over 800 characters or 20 lines into the composer becomes a `[Pasted#N]` chip, so the composer stays short; tapping the chip shows the full text and offers removal, and sending expands every token back to the full text in order so the model receives it intact. Ctrl/Cmd+N creates a new chat and Ctrl/Cmd+F opens the current-conversation search, wired at the app shell so they work on every route; neither key is taken while another editable text field has focus, while the composer keeps Ctrl/Cmd+N.
- **Chat reading width and reply actions** — on a wide (dual-pane) chat pane the message list, composer, and agent status now share one 860dp reading column and stay centered, while phone width keeps its previous rule. The message action sheet gains 复制全文 and 复制纯文本 (plain text drops the markdown markers), and a user message gains 从此处删除, which removes that message and every later message after a confirmation and refuses while the session is sending. A tool result that carries an image (a data URL or an image path) is shown in the tool card. A model stream that ends before its completion event (a dropped connection, for example) keeps the text already produced and marks the turn interrupted instead of discarding the partial assistant message.
- **Second-review hardening** — every agent notification (session status, tool approval, completion, background-task lease, group summary, auto-approved tool) is `VISIBILITY_PRIVATE` with a generic `publicVersion`, and the multi-task summary no longer repeats session titles; the MCP stdio write path rejects an oversized UTF-8 frame, serializes every frame per child, and settles pending requests immediately when a write fails; the exported share Intent bounds `EXTRA_TEXT` (64 KB), `EXTRA_SUBJECT` (1 KB), and the stream-URI list (64) natively, with a second Dart cap; a platform call that can no longer reach Dart fails with `ACTIVITY_DESTROYED` / `PLATFORM_CALL_CANCELLED` instead of leaving the future pending; Android backup now keeps chat history and non-secret settings while still excluding the encrypted credential store; the build pins NDK 27.0.12077973 (the highest version requested by the plugin matrix).
- **Third-review hardening** — `readRootfsFileBytes` now reads through the JNI broker's descriptor-relative walk (`openat` with `O_NOFOLLOW` on every component, `O_NONBLOCK` on the final file, `fstat` type and link-count verification, identity re-check after the bounded read), so a concurrent writer cannot swap a parent-directory symlink, a FIFO or device node, or a larger file into the read; `FlutterSharedPreferences.xml` is excluded from Android backup again, so a legacy plaintext `api_key` / `env_vars` from an upgraded install can never enter a backup or device transfer, while non-secret settings travel in an allowlisted `clawchat_settings_backup.json` snapshot; and `cache/shared_intents` now has a total byte and file-count quota that prunes the oldest shared images before each write and rejects a write that cannot fit.
- **Fourth-review hardening** — the share cache writes into a random `.part` file first: a failed or interrupted provider read deletes the temp file and never evicts a cached image, and the final name is only published by an atomic rename after the quota plan is accepted. Share URIs are deduplicated before the 64-item cap, so a sender that repeats one URI cannot starve a genuinely new attachment. The settings mirror now also carries non-secret provider profile identity metadata (id, name, model, sampling parameters — never the API key or base URL), and the restore runs profile placeholders first so restored model groups and the active selection survive on a new device. `importAllSettings` is now a `Future<void>` that awaits every preferences, model-group and profile write, and the fresh-restore marker is written only after all of them succeed, so an interrupted restore is retried on the next launch instead of being silently consumed.

### Residual in 2.14.0

- Legacy memory import cannot grant user trust; MCP stdio lines are capped in both directions and stdin writes are serialized per child; every agent notification is lock-screen private; `read_file` is bounded natively and `readRootfsFileBytes` reads descriptor-relative; Android backup excludes `FlutterSharedPreferences.xml` and restores settings from an allowlisted mirror; the share-image cache has a total quota; AGP is 8.13.2 and the NDK is pinned to 27.0.12077973.
- Tool-result image blocks land in this same version (2.14.0); they were not exercised on a device here.
- SAF device verification and the on-device MCP stdio smoke are **NOT RUN** and stay deferred to a later physical-device pass. No device pass is claimed for 2.14.0.
- The I7 runtime split is not part of this release.

## v2.10.0 — Linux Runtime Health

### Linux runtime
- **System Health covers the machine, not just the container** — the health destination now reports the disk used by the rootfs and its `/root/workspace`, the guest `resolv.conf` DNS status, and the last command state (running / exited / unknown). Every check is read-only local state: it starts no proot process, mounts no shared storage, and adds no telemetry or health score. Low free space, a missing nameserver, and an unknown last command ask the user to act; a failed check stays **unknown**, never ready.
- **Command lifecycle in chat** — a bash attempt shows `started`, `running`, `completed`, `cancelled`, or `interrupted-unknown`. The `running` signal comes from the live tooling status, `cancelled` from the existing cancellation result, and `interrupted-unknown` from the interrupted run marker. After the app is killed mid-command the card states that the command did not finish; there is no silent retry.
- **Workspace boundary** — agent bash still does not bind `/storage` or `/sdcard`. A Dart regression test pins the `mountStorage: false` argument and the absence of any storage-mount input, and a JVM test pins the native flag builder (`buildInstallCommand(..., mountStorage = false)`) against a default `/storage` bind. `MANAGE_EXTERNAL_STORAGE` is retained for user-initiated flows only; it never becomes an agent-bash bind.
- **No new durable process** — this lane adds no daemon, MCP supervisor, or additional foreground-service owner. It tracks user-started commands tied to an agent run or one-shot terminal/bash.

## v2.9.0 — Phone Senses

### Phone data and actions
- **Split phone tools** — `phone_read` (calendar, SMS, contacts), `phone_act` (alarm, share, navigation, calendar UI), and `phone_send` (call, SMS). `phone_intent` stays registered but hidden as a one-version compatibility alias.
- **SMS read** — `listSms` / `getSms` with `READ_SMS` requested at first use. Bounded snippets (280 chars) and bodies (4000 chars), default limit 20 / max 50, no `RECEIVE_SMS`, no broadcast watcher, no body logging.
- **Tighter calendar and contacts reads** — calendar default window is start of today → +7 days, with a title/location/description query, default limit 20 / max 50, `allDay`, local ISO times, and a redacted `description` (URLs, emails, `tel:`). Contacts accept a query, or a limit capped at 10, so the address book is never dumped.
- **Outbound stays default-off** — `phone_send` returns `disabled_by_user` until the matching setting is on; SMS still confirms per send and fails closed when the app is not resumed.

### Untrusted tool data
- **Run-scoped taint** — `phone_read` results and `web_fetch` / `web_search` bodies are tagged `trust: untrusted` on the transcript entry and feed a run-scoped taint set. A tainted destination is hard-denied for `phone_send`, the local-handoff `phone_act` actions, `bash` network exfil, and the hidden `phone_intent` alias.
- **Complete `bash` network matcher** — beyond `curl` / `wget` / `nc`, a tainted destination is hard-denied for `busybox wget`, `python3` / `python` using `urllib` / `http.client` / `requests`, `git` `clone` / `fetch` / `push` / `ls-remote`, the `node` / `nodejs` / `bun` deny class below, and any unknown binary whose arguments carry a tainted URL or host. This is not a default-deny outbound firewall.
- **Match bar** — the deny also fires on URLs, hosts, `tel:` numbers, and emails extracted from the untrusted payload, so an SMS that says `go to evil.example` blocks `curl https://evil.example` and `openWeb` even though the tool argument is not a raw substring of the SMS.
- **Memory laundering is closed** — a `memory_write` of a value that arrived from untrusted tool data is stored as untrusted; a later `memory_get` re-seeds the run taint set with the original source, so a subsequent `curl` / `phone_send` of that value is hard-denied. The trust flags live in **encrypted app storage** (`flutter_secure_storage`, key `clawchat.memory_untrusted.v1`), not a file the guest shell can rewrite; the pre-2.9.0 rootfs file and the interim plain file are imported once (merged) and deleted. An absent or unreadable trust entry with stored facts, and any fact with no recorded provenance, fails closed as untrusted. Untrusted facts are also listed under a separate **Untrusted memories** prompt heading, and the run taint set is seeded from them at run start even when the session replays no tool result. The flag clears when the user deletes the fact in Settings (or the exact stored text is confirmed through `MemoryService.confirmMemoryText`, which is not a model-facing tool); an ordinary user-typed write stays trusted. If the trust store cannot be read, every stored fact is treated as untrusted.
- **History replay is enforced** — at the start of a run the taint set is seeded from prior transcript tool results whose `trust` is `untrusted`, so a phone number read in one turn still hard-denies `phone_send` in the next. Only the **triggering** user message clears a value; an older typed URL does not.
- **Background share is checked** — before a `share_text_v1` task runs, its text is compared with untrusted tool-result values already in the session transcript; a match denies the task. An unreadable transcript fails closed.
- **Web→web follow is Ask** — following a link found in fetched content shows the approval card with the exact URL, in-app and in the background notification (which carries the URL as `detail`), even when Auto Allow is on. Web taint is only cleared for the exact URL the user confirmed.
- **Sequential tools only** — parallel tool execution is rejected before any tool starts, so a sibling call cannot race the taint set.
- **Behavior change** — following a link found in a fetched page used to be silent; it now requires Ask.
- **One canonicalization layer** — before every bash / phone / web match the argument is canonicalized: percent-decoding, one base64 layer (an argument fed to `base64 -d` / `--decode`, or a single argument that decodes to a URL, host, email, or phone), and empty-string quote-splitting (`""` / `''`). Nested encodings stay out.
- **Redirect hops are checked** — `web_fetch` keeps `followRedirects = false` and checks every `Location` hop against the run taint set, hard-denying before that hop is requested. A web→web chain that is not otherwise tainted still uses the existing Ask path.
- **`node` / `nodejs` / `bun`** — a named deny class like python: denied with a tainted URL or host, and an eval flag (`-e`, `--eval`, `-p`, `--print`) denied outright when any tainted value is in the command. `node` is **not** installed in the Alpine baseline.
- **Same-run file copies** — a `write_file` whose content matches the run taint set marks the normalized `/root/workspace` path; a later `read_file` of that path returns `trust: untrusted` with its original source and re-seeds the same run taint set; bash that reads that path while carrying a tainted destination is hard-denied. The path set is in-memory for the run only: a new run does not inherit file taint and nothing survives a restart.

### Permission recovery
- **One-tap Fix** — a `phone_read` result that returns `permission_required` shows a **打开权限设置** button in the chat tool card that opens the OS App details screen (`ACTION_APPLICATION_DETAILS_SETTINGS`). If the native open fails the text instruction remains and the run continues.
- **No prompt loop** — each runtime permission is requested at most once per activity lifetime; later calls return the stable `permission_required` code with the exact Settings path.

### Product boundary
- **PRODUCT.md** — thesis, the two runtimes, non-goals, privacy, and a written owner scenario for every manifest permission.
- **Settings** — “手机集成” is now “手机数据与动作”, with separate 读取 and 外发 rows. The existing `allow_phone_call` / `allow_sms` keys are preserved on upgrade.
- **Default system prompt** — describes the Alpine-hosted machine and the phone tools; it states that phone read works only after the runtime permission is granted.
- `READ_SMS` is added. `RECEIVE_BOOT_COMPLETED` is retained for the persisted cleanup job.

### Compatibility
- Includes the v2.6–v2.8 gates. Transcripts written before 2.9.0 have no `trust` field and read back as trusted. Memory entries written before 2.9.0 have no untrusted flag and read back as trusted.

### Known residual (not closed by 2.9.0)
- DNS rebinding, IP-literal versus hostname, and homograph / punycode domains are not detected: the matcher compares strings, not resolved addresses.
- There is no default-deny outbound firewall; an unknown binary with no tainted URL or host is allowed.
- Nested encodings, non-empty shell concatenation, shortlink services whose hop is never fetched, and `perl` / `eval` indirection are not covered.

## v2.13.0 — Background Honesty

- **The island is developer tooling** — Dynamic Island / floating status is behind Developer Mode and **off by default**. A normal install and the first agent run never prompt for `SYSTEM_ALERT_WINDOW`; the overlay permission is requested only after Developer Mode is on and the user enables the 灵动岛 / 悬浮状态 toggle. Turning Developer Mode off turns the island off and hides any existing overlay. The island code is kept, not deleted.
- **Notification copy describes the machine** — status lines read as a machine doing work (机器正在思考 / 机器正在执行工具 / 机器仍在运行), and the completion summary is 机器任务完成. Notification-only is the core path; the island is an add-on.
- **Stop cancels only that session** — the notification Stop action still cancels the single session that raised it, leaving parallel sessions running. Existing durable receipts and `unknown_outcome` behavior are unchanged; there is no automatic resume after process death or reboot, and `RECEIVE_BOOT_COMPLETED` is not used to start an agent run.

## v2.12.0 — MCP in proot

- **Run-scoped stdio MCP bridge** — Android now starts stdio MCP servers inside Alpine through a proot bridge instead of refusing them. A child starts for the agent run that needs its tools and is killed when that run ends, is cancelled, or the foreground-service lease drops. There is no durable MCP supervisor and no restart after process death.
- **Allowlisted environment, never inheritance** — the guest environment is only the fixed `HOME` / `PATH` / `LANG` / `TMPDIR` baseline plus the keys the user typed on that `McpServerConfig.env`. `GOOGLE_ACCESS_TOKEN` and other app secrets are never copied in. The values are written to an app-private launch script rather than the process argument vector. Docs and settings now state that MCP env is not the place for Gmail/Drive tokens.
- **A failed start is visible** — when proot is not ready, the child crashes, or a start times out, settings and the tool result show the reason instead of an empty tool list. The Alpine readiness answer is surfaced in the MCP settings section.
- **MCP results are untrusted** — every MCP tool result is tagged `trust: untrusted` with source `mcp` and enters the existing deny engine, so an MCP result cannot drive `phone_send`, the local-handoff `phone_act` sinks, or a tainted `curl` / web destination without the user typing or confirming the value.
- **Device smoke not run** — the on-device smoke (pinned stdio server starting for one run, listing a tool, executing it, child gone at run end) is **not run** in this lane and is not claimed as a device pass.

## v2.11.0 — Skills disposition

- **Fate table applied** — every bundled preset now has one explicit fate. `gws-calendar`, `gws-gmail`, `gws-drive`, `web-search`, `file-manager`, and `system-info` ship and are installed **disabled**; the existing legacy skill consent is the only unlock.
- **Google presets are Google API, not phone data** — settings and each preset state that Gmail / Drive / Calendar call Google APIs, there is **no in-app OAuth**, and the user must supply `GOOGLE_ACCESS_TOKEN` in environment variables. Asking about the phone calendar uses `phone_read` and does not require the token or `gws-calendar`.
- **`web-search` points at the host tool** — the preset now calls the built-in `web_search` / `web_fetch` tools instead of ad-hoc shell fetching.
- **`file-manager` and `system-info` rewritten** — `file-manager` describes workspace + Android SAF (not whole-device storage); `system-info` describes machine health in the Alpine/proot runtime (not `uname` presented as phone state).
- **`github`, `translator`, `code-review` leave the app bundle** — they move to `docs/skill-examples/` as examples. Left-over installed copies of the old preset IDs stay blocked, and `code-review` is not installed by default. A skill markdown still cannot grant `phone_send` or bypass Ask.

## v2.8.0 — Safe Background Tasks

### Durable local tasks

- **Preview-first task state** — Adds bounded protected local task records, explicit finite task definitions, durable receipts, recovery-required/unknown-outcome states, and no automatic retry or resume.
- **Owner-scoped foreground lease** — Native Android only holds a task owner lease and privacy-safe notification; request-level readiness, interruption fencing, collision-safe notification IDs, and stop isolation prevent effects without the active lease.
- **Two-confirmation external flow** — External work requires plan approval plus just-in-time confirmation with task-bound target evidence; task center recovery exposes inspect/discard only and never dispatches from notifications.

### Compatibility

- Includes the v2.7 fixed-schema result/action UI and all v2.6 Skill discovery, consent, import-inspection, authorization, and foldable-safety gates.

## v2.7.0 — Fixed Schema Results and Optional Rich Display

### Results and actions

- **Strict structured results** — Accepts only the bounded v1 document schema with deterministic plain-text projection, API chronology preservation, invalid-data fallback, and durable local presentation.
- **Native action lifecycle** — Keeps approval, hard-deny, skill authorization, fresh operation IDs, receipt persistence, restart reconciliation, and effect execution in native Flutter; the only initial action is the exact app-owned local memory write.
- **Accessible result UI** — Provides four fixed block renderers, 48dp semantics-aware controls, 200% text support, and compact/book/tabletop/IME geometry protection.

### Optional rich surface

- **MCP App-style supplement** — A host-owned fixed local WebView renderer can be explicitly expanded beside the native card for bounded detail display. It accepts no arbitrary HTML, URL, tool, secret, or payload; actions return only result/action IDs to the native policy and receipt path, and geometry changes collapse it safely.

## v2.6.2 — xd-skill Discovery and Consent Repair

### Skill Management

- **CLI skill discovery** — Finds skills installed by `xd-skill` under `/root/workspace/.agents/skills` in addition to App-managed skills under `/root/workspace/skills`.
- **Explicit consent and activation** — Shows CLI-managed skills in Settings, supports explicit consent/enable, and activates the uniquely installed skill by stable ID with fresh digest verification.
- **Ownership-safe actions** — Keeps Update, History, and Rollback disabled for CLI-managed skills so package lifecycle remains owned by `xd-skill`.
- **Conflict protection** — Excludes duplicate enabled IDs from the model index and rejects consent when the same stable ID exists at another installed path.

### Compatibility

- Preserves the v2.6.1 UI and brand refresh and the v2.6.0 Skill Eval, import-inspection, authorization, and foldable-safety gates.

## v2.6.1 — UI and Brand Refresh Integration

### User Experience

- **Focused chat surface** — Restores the grouped command menu, local-workspace empty state, reduced assistant chrome, and clearer session-aware actions.
- **Production-theme contrast** — Uses the real light and dark theme surfaces for selected sessions and keeps readable on-surface foregrounds.
- **Cleaner maintenance UI** — Reduces repeated bordered containers in settings and tool results while preserving existing interaction semantics.
- **Brand and privacy alignment** — Adds adaptive and round launcher icons, exposes the privacy policy from About, and aligns the public privacy copy with the local-first architecture.

### Compatibility

- Includes all v2.6.0 skill-eval, import-inspection, legacy-preset, authorization, and foldable-safety changes unchanged.
- Release builds now fail closed unless the official signing configuration is present, and the packaged APK signer, package, and version are verified before publication.

## v2.6.0 — Host-Owned Skill Evals and Safe Import Inspection

### Security and Quality Gates

- **Host-owned Skill Evals** — Binds all nine shipped skill assets to exact SHA-256 inventory entries, a closed repository-owned corpus, strict schemas, deterministic goldens, and positive/negative/near-miss coverage.
- **Inert device import inspection** — Parses bounded imported bytes without executing archive-provided scripts, tools, models, JavaScript, or network requests; reports only fixed rule IDs and count-only capability summaries.
- **Strict manifest parsing** — Rejects invalid UTF-8, BOMs, duplicate JSON keys, unknown fields, unsupported manifest versions, invalid integrity metadata, oversized files, unsafe archive paths, and duplicate normalized members before extraction.
- **Non-authorizing eval invariant** — A passing host eval or import inspection cannot bypass global hard denies, per-skill capability checks, Ask, Auto Allow eligibility, or recovery reauthorization.

### Bundled Preset Safety

- **Nine legacy presets locked** — Existing bundled presets remain unavailable with a fixed user-visible reason until their advertised behavior can be enforced by current runtime policy.
- **Catalog and runtime closure** — Locked presets cannot install, enable, enter the model index, load by ID/path, update, restore, or roll back; similarly named third-party nested skills remain unaffected.
- **Accessible status UI** — Locked states and import inspection summaries are covered at 320dp/200% text, book-fold hinge, tabletop posture, and IME layouts.

---

## v2.3.0 — Multi-Session Parallel AI

### New Features

- **多会话并行 Agent** — 多个 chat session 可同时运行 AI agent，每个 session 独立维护发送状态、streaming 文本、队列、LLM client 与错误状态
- **每会话通知** — Android 前台服务通知按 session 独立显示状态和预览，多任务时自动分组并显示 summary；通知栏停止按钮只取消对应 session
- **灵动岛轮播** — 后台多个 agent 同时运行时，悬浮窗灵动岛每 3 秒轮播不同 session 的状态；单 session 时保持原有无编号展示
- **Session 状态指示** — 会话列表显示 agent 运行状态 badge，便于快速识别正在思考、回复、执行工具或出错的会话

### Bug Fixes

- **删除运行中会话** — 删除 session 前会先取消该 session 的 agent 并清理状态，避免残留通知或后台任务
- **并发工具授权** — 非当前 session 的工具授权按后台任务处理，不会抢占当前会话的授权弹窗
- **环境变量修改提示** — 有 agent 运行时修改环境变量会提示“下次启动 Agent 时生效”

---

## v2.2.0 — Message Queue, Config Backup & Agent UX

### New Features

- **消息队列** — AI 回复过程中可以继续输入和发送消息，FIFO 排队（上限 3 条），当前回复完成后自动发送下一条。取消 agent 时队列保留，用户可手动发送或清空
- **配置导入/导出** — 支持将 Provider Profiles（含 API 密钥）、环境变量、应用设置导出为 JSON 文件。默认 AES-256-GCM 加密（PBKDF2-SHA256 密钥推导），可选明文导出（带风险提示）。导入支持预览、密码解密、冲突策略（合并/覆盖/跳过）
- **环境变量隐私模式** — 工具执行输出发送给 LLM 前自动脱敏环境变量值（默认开启），聊天 UI 中用户仍看到原始输出
- **Agent 最大轮次可配置** — 设置页 Slider 调整，范围 1-99，默认 25

### Bug Fixes

- **取消 Agent 时保留部分回复** — 之前取消会丢弃所有已收到的内容，现在保存已完成轮次和正在 streaming 的部分文本
- **多轮任务增量显示** — Agent 每完成一轮（工具调用+结果）立即写入聊天记录并在 UI 显示，不再等整个任务完成
- **多模型对比修复** — 修复无 session 时静默失败、深色模式透明背景、三模型对比无反应、错误反馈缺失等问题
- **灵动岛回前台不消失** — 回前台无条件隐藏 overlay，不再依赖 `_isSending` 状态
- **Agent error 卡住** — AgentError 时补全 completer，防止 UI 停留在 thinking 状态

---

## v2.1.0 — Background Stream Resilience & Dynamic Island

### New Features

- **Dynamic Island Overlay** — 后台运行 Agent 时在屏幕顶部显示灵动岛胶囊，实时展示思考/回复/工具执行状态。状态变化时自动向下展开显示预览，3 秒后收缩。点击跳回 App，完成时变为主题蓝色后消失。需悬浮窗权限，拒绝则静默降级为通知
- **增强前台通知** — Agent 运行时通知栏实时更新状态标题、输出预览（BigTextStyle 展开）、thinking 阶段进度条，并提供"查看"和"停止"操作按钮。原生侧 500ms 节流防止 ANR
- **Heads-up 完成通知** — Agent 后台完成后弹出横幅卡片通知（IMPORTANCE_HIGH），点击跳转查看回复

### Bug Fixes

- **后台流式请求断连** — 所有 LLM 代理（Mimo、Anthropic、OpenAI 兼容）切后台时 HTTP 连接被代理/系统关闭导致 `Connection closed while receiving data`。添加 HTTP Keep-Alive 头 + 统一重连机制（最多 2 次，指数退避）+ 重连去重（跳过已输出内容避免重复）
- **后台 Timeout 误触发** — `.timeout(60s)` 在 Dart event loop 被系统挂起时仍然计时，后台超 60 秒必然假超时。改为手动 Timer + `isInBackground` 检查，后台时不触发超时

### Enhancements

- **国产手机悬浮窗适配** — 小米 MIUI / 华为 HarmonyOS 权限跳转 intent 适配，OPPO/vivo 悬浮窗拦截时 try-catch 静默降级
- **通知停止按钮** — 通知栏"停止"按钮通过 MethodChannel 回调 Dart 侧 `cancelAgent()`，延迟 1 秒再停止服务确保清理完成

---

## v1.8.6 — Config Repair, Gateway Mode & Node.js Update

### Bug Fixes

- **Config Corruption Fix (#83, #88)** — Provider model entries were written as bare strings instead of objects (`{ id: "model-name" }`), causing OpenClaw config validation to reject the file with "expected object, received string". Fixed both the Node.js script path and the direct file I/O fallback in `ProviderConfigService`. Existing corrupted configs are now auto-repaired on gateway init
- **Gateway Start Failure (#93, #90)** — The gateway blocked with "set gateway.mode=local (current: unset)". Now `gateway.mode=local` is set automatically in openclaw.json during provider config saves, gateway config writes, bionic bypass installation, and on startup repair
- **Config Auto-Repair on Init (#88)** — Added `_repairConfigFile()` that runs on every `GatewayService.init()` to fix corrupted model entries and missing `gateway.mode`, preventing the crash-restart loop (5 restarts → stopped)
- **Bionic Bypass Installation Robustness (#94)** — Added retry logic with parent directory creation if the initial `mkdirs()` fails silently on some devices
- **Pre-seed Config on Setup** — `installBionicBypass()` now creates a default `openclaw.json` with `gateway.mode=local` during initial setup, so the gateway works immediately after installation
- **Setup Re-prompt After Node Upgrade (#97)** — Expanded auto-repair on splash screen to reinstall Node.js and OpenClaw when their binaries are missing but rootfs is intact, instead of forcing a full re-setup

### Enhancements

- **Node.js Updated to 22.14.0** — Upgraded from 22.13.1 to latest 22.x LTS for better stability and compatibility (#87)
- **npm Package Synced to 1.8.6** — Updated package.json version, refreshed dependencies, bumped engine to Node >= 22
- **Removed Outdated Model** — Dropped `claude-3-5-sonnet-20241022` from Anthropic provider defaults

---

## v1.8.4 — Serial, Log Timestamps & ADB Backup

### New Features

- **Serial over Bluetooth & USB (#21)** — New `serial` node capability with 5 commands (`list`, `connect`, `disconnect`, `write`, `read`). Supports USB serial devices via `usb_serial` and BLE devices via Nordic UART Service (flutter_blue_plus). Device IDs prefixed with `usb:` or `ble:` for disambiguation
- **Gateway Log Timestamps (#54)** — All gateway log messages (both Kotlin and Dart side) now include ISO 8601 UTC timestamps for easier debugging
- **ADB Backup Support (#55)** — Added `android:allowBackup="true"` to AndroidManifest so users can back up app data via `adb backup`

### Enhancements

- **Check for Updates (#59)** — New "Check for Updates" option in Settings > About. Queries the GitHub Releases API, compares semver versions, and shows an update dialog with a download link if a newer release is available

### Bug Fixes

- **Node Capabilities Not Available to AI (#56)** — `_writeNodeAllowConfig()` silently failed when proot/node wasn't ready, causing the gateway to start with no `allowCommands`. Added direct file I/O fallback to write `openclaw.json` directly on the Android filesystem. Also fixed `node.capabilities` event to send both `commands` and `caps` fields matching the connect frame format

### Node Command Reference Update

| Capability | Commands |
|------------|----------|
| Serial | `serial.list`, `serial.connect`, `serial.disconnect`, `serial.write`, `serial.read` |

---

## v1.8.3 — Multi-Instance Guard

### Bug Fixes

- **Duplicate Gateway Processes (#48)** — Services now guard against re-entry when Android re-delivers `onStartCommand` via `START_STICKY`, preventing duplicate processes, leaked wakelocks, and repeated answers to connected apps
- **Wakelock Leaks** — All 5 foreground services release any existing wakelock before acquiring a new one
- **Orphan PTY Instances** — Terminal, onboarding, configure, and package install screens now kill the previous PTY before starting a new one on retry
- **Notification ID Collisions** — SetupService and ScreenCaptureService no longer share notification IDs with other services

---

## v1.8.2 — DNS Reliability, Screenshot Capture, Custom Models & Setup Detection

### Bug Fixes

- **Setup State Detection (#44)** — `openclawx onboard` no longer says setup isn't done after a successful setup. Replaced slow proot exec check with fast filesystem check for openclaw detection, with a longer-timeout fallback
- **DNS / No Internet Inside Proot (#45)** — resolv.conf is now written to both `config/resolv.conf` (bind-mount source) and `rootfs/ubuntu/etc/resolv.conf` (direct fallback) at every entry point: app start, every proot invocation, gateway start, SSH start, and all terminal screens. Survives APK updates
- **NVIDIA NIM Config Breaks Onboarding (#46)** — Provider config save now falls back to direct file write if the proot Node.js one-liner fails (e.g. due to DNS issues)

### New Features

- **Screenshot Capture** — All terminal and log screens now have a camera button to capture the current view as a PNG image saved to device storage
- **Custom Model Support (#46)** — AI Providers screen now allows entering any custom model name (e.g. `kimi-k2.5`) via a "Custom..." option in the model dropdown
- **Updated NVIDIA Models (#46)** — Added `meta/llama-3.3-70b-instruct` and `deepseek-ai/deepseek-r1` to NVIDIA NIM default models

### Reliability

- **resolv.conf at Every Entry Point** — `MainActivity.configureFlutterEngine()` ensures directories and resolv.conf exist on every app launch. `ProcessManager.ensureResolvConf()` guarantees it before every proot invocation. All Kotlin services and Dart screens have independent fallbacks writing to both paths
- **APK Update Resilience** — Directories and DNS config are recreated on engine init, so the app recovers automatically after an APK update clears filesDir

---

## v1.8.0 — AI Providers, SSH Access, Ctrl Keys & Configure Menu

### New Features

- **AI Providers** — New "AI Providers" screen to configure API keys and select models for 7 providers: Anthropic, OpenAI, Google Gemini, OpenRouter, NVIDIA NIM, DeepSeek, and xAI. Writes configuration directly to `~/.openclaw/openclaw.json`
- **SSH Remote Access** — New "SSH Access" screen to start/stop an SSH server (sshd) inside proot, set the root password, and view connection info with copyable `ssh` commands. Runs as an Android foreground service for persistence
- **Configure Menu** — New "Configure" dashboard card opens `openclaw configure` in a built-in terminal for managing gateway settings
- **Clickable URLs** — Terminal and onboarding screens detect URLs at tap position (joining adjacent lines, stripping box-drawing characters) and offer Open/Copy/Cancel dialog

### Bug Fixes

- **Ctrl Key with Soft Keyboard (#37)** — Ctrl and Alt modifier state from the toolbar now applies to soft keyboard input across all terminal screens (terminal, configure, onboarding, package install). Previously only worked with toolbar buttons
- **Ctrl+Arrow/Home/End/PgUp/PgDn (#38)** — Toolbar Ctrl modifier now sends correct escape sequences for arrow keys and navigation keys (e.g. `Ctrl+Left` sends `ESC[1;5D`)
- **resolv.conf ENOENT after Update (#40)** — DNS resolution failed after app update because `resolv.conf` was missing. Now ensured on every app launch (splash screen), before every proot operation (`getProotShellConfig`), and in the gateway service init — covering reinstall, update, and normal launch

### Dashboard

- Added "AI Providers" and "SSH Access" quick action cards

---

## v1.7.3 — DNS Fix, Snapshot & Version Sync

### Bug Fixes

- **DNS Breaks After a While (#34)** — `resolv.conf` is now written before every gateway start (in both the Flutter service and the Android foreground service), not just during initial setup. This prevents DNS resolution failures when Android clears the app's file cache
- **Version Mismatch (#35)** — Synced version strings across `constants.dart`, `pubspec.yaml`, `package.json`, and `lib/index.js` so they all report `1.7.3`

### New Features

- **Config Snapshot (#27)** — Added Export/Import Snapshot buttons under Settings > Maintenance. Export saves `openclaw.json` and app preferences to a JSON file; Import restores them. A "Snapshot" quick action card is also available on the dashboard
- **Storage Access** — Added Termux-style "Setup Storage" in Settings. Grants shared storage permission and bind-mounts `/sdcard` into proot, so files in `/sdcard/Download` (etc.) are accessible from inside the Ubuntu environment. Snapshots are saved to `/sdcard/Download/` when permission is granted

---

## v1.7.2 — Setup Fix

### Bug Fixes

- **node-gyp Python Error** — Fixed `PlatformException(PROOT_ERROR)` during setup caused by npm's bundled node-gyp failing to find Python. Now installs `python3`, `make`, and `g++` in the rootfs so native addon compilation works properly
- **tzdata Interactive Prompt** — Fixed setup hanging on continent/timezone selection by pre-configuring timezone to UTC before installing python3
- **proot-compat Spawn Mock** — Removed `node-gyp` and `make` from the mocked side-effect command list since real build tools are now installed

---

## v1.7.1 — Background Persistence & Camera Fix

> Requires Android 10+ (API 29)

### Node Background Persistence

- **Lifecycle-Aware Reconnection** — Handles both `resumed` and `paused` lifecycle states; forces connection health check on app resume since Dart timers freeze while backgrounded
- **Foreground Service Verification** — Watchdog, resume handler, and pause handler all verify the Android foreground service is still alive and restart it if killed
- **Stale Connection Recovery** — On app resume, detects if the WebSocket went stale (no data for 90s+) and forces a full reconnect instead of silently staying in "paired" state
- **Live Notification Status** — Foreground notification text updates in real-time to reflect node state (connected, connecting, reconnecting, error)

### Camera Fix

- **Immediate Camera Release** — Camera hardware is now released immediately after each snap/clip using `try/finally`, preventing "Failed to submit capture request" errors on repeated use
- **Auto-Exposure Settle** — Added 500ms settle time before snap for proper auto-exposure/focus
- **Flash Conflict Prevention** — Flash capability releases the camera when torch is turned off, so subsequent snap/clip operations don't conflict
- **Stale Controller Recovery** — Flash capability detects errored/stale controllers and recreates them instead of failing silently

---

## v1.7.0 — Clean Modern UI Redesign

> Requires Android 10+ (API 29)

### UI Overhaul

- **New Color System** — Replaced default Material 3 purple with a professional black/white palette and red (#DC2626) accent, inspired by Linear/Vercel design language
- **Inter Typography** — Added Google Fonts Inter across the entire app for a clean, modern feel
- **AppColors Class** — Centralized color constants for consistent theming (dark bg, surfaces, borders, status colors)
- **Dark Mode** — Near-black backgrounds (#0A0A0A), subtle surface (#121212), bordered cards
- **Light Mode** — Clean white backgrounds, light borders (#E5E5E5), bordered cards

### Component Redesign

- **Zero-Elevation Cards** — All cards now use 1px borders with 12px radius instead of drop shadows
- **Pill Status Badges** — Gateway and Node controls show pill-shaped badges (icon + label) instead of 12px status dots
- **Monochrome Dashboard** — Removed rainbow icon colors from quick action cards; all icons use neutral muted tones
- **Uppercase Section Headers** — Settings, Node, and Setup screens use letterspaced muted grey headers
- **Red Accent Buttons** — Primary actions (Start Gateway, Enable Node, Install) use red filled buttons; destructive/secondary actions use outlined buttons
- **Terminal Toolbar** — Aligned colors to new palette; CTRL/ALT active state uses red accent; bumped border radius

### Splash Screen

- **Fade-In Animation** — 800ms fade-in on launch with easeOut curve
- **App Icon Branding** — Uses ic_launcher.png instead of generic cloud icon
- **Inter Bold Wordmark** — "OpenClaw" displayed in Inter weight 800 with letter-spacing

### Polish

- **Log Colors** — INFO lines use muted grey (not red); WARN uses amber instead of orange
- **Installed Badges** — Package screens use consistent green (#22C55E) for "Installed" badges
- **Capability Icons** — Node screen capabilities use muted color instead of primary red
- **Input Focus** — Text fields highlight with red border on focus
- **Switches** — Red thumb when active, grey when inactive
- **Progress Indicators** — All use red accent color

### CI

- Removed OpenClaw Node app build from workflow (gateway-only CI now)

---

## v1.6.1 — Node Capabilities & Background Resilience

> Requires Android 10+ (API 29)

### New Features

- **7 Node Capabilities (15 commands)** — Camera, Flash, Location, Screen, Sensor, Haptic, and Canvas now fully registered and exposed to the AI via WebSocket node protocol
- **Proactive Permission Requests** — Camera, location, and sensor permissions are requested upfront when the node is enabled, before the gateway sends invoke requests
- **Battery Optimization Prompt** — Automatically asks user to exempt the app from battery restrictions when enabling the node

### Background Resilience

- **WebSocket Keep-Alive** — 30-second periodic ping prevents idle connection timeout
- **Connection Watchdog** — 45-second timer detects dropped connections and triggers reconnect
- **Stale Connection Detection** — Forces reconnect if no data received for 90+ seconds
- **App Lifecycle Handling** — Auto-reconnects node when app returns to foreground after being backgrounded
- **Exponential Backoff** — Reconnect attempts use 350ms-8s backoff to avoid flooding

### Fixes

- **Gateway Config** — Patches `/root/.openclaw/openclaw.json` to clear `denyCommands` and set `allowCommands` for all 15 commands (previously wrote to wrong config file)
- **Location Timeout** — Added 10-second time limit to GPS fix with fallback to last known position
- **Canvas Errors** — Returns honest `NOT_IMPLEMENTED` errors instead of fake success responses
- **Node Display Name** — Renamed from "OpenClaw Termux" to "OpenClawX Node"

### Node Command Reference

| Capability | Commands |
|------------|----------|
| Camera | `camera.snap`, `camera.clip`, `camera.list` |
| Canvas | `canvas.navigate`, `canvas.eval`, `canvas.snapshot` |
| Flash | `flash.on`, `flash.off`, `flash.toggle`, `flash.status` |
| Location | `location.get` |
| Screen | `screen.record` |
| Sensor | `sensor.read`, `sensor.list` |
| Haptic | `haptic.vibrate` |

---

## v1.5.5

- Initial release with gateway management, terminal emulator, and basic node support
