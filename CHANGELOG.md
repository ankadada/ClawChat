# Changelog

## v2.6.1 — UI and Brand Refresh Integration

### User Experience

- **Focused chat surface** — Restores the grouped command menu, local-workspace empty state, reduced assistant chrome, and clearer session-aware actions.
- **Production-theme contrast** — Uses the real light and dark theme surfaces for selected sessions and keeps readable on-surface foregrounds.
- **Cleaner maintenance UI** — Reduces repeated bordered containers in settings and tool results while preserving existing interaction semantics.
- **Brand and privacy alignment** — Adds adaptive and round launcher icons, exposes the privacy policy from About, and aligns the public privacy copy with the local-first architecture.

### Compatibility

- Includes all v2.6.0 skill-eval, import-inspection, legacy-preset, authorization, and foldable-safety changes unchanged.

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
