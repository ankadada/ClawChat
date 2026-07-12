---
version: alpha
name: ClawChat
description: Local-first Android AI chat with explicit consent, recoverable actions, and foldable-safe maintenance surfaces.
colors:
  primary: "#2563EB"
  surface-light: "#FFFFFF"
  surface-light-alt: "#F9F9F9"
  surface-dark: "#1E1E26"
  background-dark: "#141418"
  border-light: "#E5E5E5"
  border-dark: "#343442"
  on-surface-light: "#141418"
  on-surface-dark: "#FFFFFF"
  muted: "#6B7280"
  success: "#22C55E"
  warning: "#F59E0B"
  error: "#EF4444"
typography:
  title: {fontFamily: "Android platform default", fontSize: "20px", fontWeight: 700, lineHeight: 1.25}
  body: {fontFamily: "Android platform default", fontSize: "16px", fontWeight: 400, lineHeight: 1.5}
  label: {fontFamily: "Android platform default", fontSize: "14px", fontWeight: 600, lineHeight: 1.35}
  code: {fontFamily: "Android platform monospace", fontSize: "14px", fontWeight: 400, lineHeight: 1.45}
rounded: {sm: "8px", md: "12px", lg: "16px", pill: "24px"}
spacing: {one: "4px", two: "8px", three: "12px", four: "16px", six: "24px", eight: "32px", touch: "48px"}
components:
  primary-action:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.on-surface-dark}"
    typography: "{typography.label}"
    rounded: "{rounded.md}"
    height: "{spacing.touch}"
  settings-row:
    backgroundColor: "{colors.surface-light-alt}"
    textColor: "{colors.on-surface-light}"
    typography: "{typography.body}"
    rounded: "{rounded.md}"
    padding: "{spacing.three} {spacing.four}"
---

# ClawChat Design and Interaction Contract

This specification extracts the current Flutter/Material truth from [`flutter_app/lib/app.dart`](flutter_app/lib/app.dart), the shared [foldable model](flutter_app/lib/layout/foldable_layout.dart), and current screens/widgets. It introduces no new brand palette or font. Architecture lives in [`ARCHITECTURE.md`](ARCHITECTURE.md).

## 1. Product and interaction principles

ClawChat behaves like a dependable local tool: chat stays primary, maintenance is secondary, and risky actions slow down at the exact trust boundary. Local state is authoritative. External processing, JavaScript, tool execution, imports, destructive data actions, and installation require explicit scope-appropriate consent. Reversible actions expose Undo, history, backup, or rollback.

Never add mandatory accounts, silent cloud sync, telemetry, background upload, automatic update download/install, implicit clipboard writes, hidden network activation, or health-score gamification.

## 2. Color semantic roles and non-color state

`primary` is the existing `AppColors.accent`. Surface, border, muted, success, warning, and error tokens come directly from `AppColors` and Material `ColorScheme`. `primary` on `surface-light` meets WCAG AA for normal text. Status colors support icons/background accents; readable text uses on-surface roles.

Every status pairs color with an icon and explicit text such as Ready, Needs action, or Unknown. Disabled actions explain the unmet condition. Color is never the sole state signal.

## 3. Typography, platform scaling, and code roles

The app bundles no brand font. `ThemeData` uses the Android platform typeface and composes user preference with platform `TextScaler`; it never overrides system font size. Title, body, and label follow the current Material scale. Commands, paths, and structured arguments use platform monospace and remain selectable.

Layouts work at 200% text. Never reduce platform scaling, lock fixed text heights, or truncate the only action/state label merely to fit.

## 4. Spacing, grid, breakpoints, and foldable safe regions

Spacing follows the existing 4dp rhythm with 8/12/16/24/32dp composition steps and a minimum 48dp target. Compact layouts begin at 320dp. Flat screens use one pane until the existing wide threshold, then retain adjustable list/detail width.

Book posture puts index/list and detail/chat in separate unobstructed regions. No divider, control, sheet action, or composer sits under the hinge. Tabletop posture selects the upper or lower region using fold geometry, usable height, and IME insets; auxiliary content stays outside the fold. Fold/unfold, posture, orientation, and IME changes preserve selected destination/session, forms/drafts, scroll, running work, context, and search without duplicate checks.

## 5. Layout and composition: chat, settings, and System Health

Chat is the normal post-splash home and exposes Local or External context without endpoint or credential identifiers.

Settings starts with eight task destinations: Connections; Agent & Tools; Voice; Data & Recovery; Updates & Extensions; Privacy; Developer; Appearance & About. Search indexes user-facing labels and safe keywords only. Compact screens push detail routes; book/wide screens keep index and detail visible with normal back behavior. Dangerous/developer controls require deliberate destination navigation.

System Health is a secondary maintenance surface showing only actionable local runtime, execution context, storage/recovery, update/extension, and task state. Unavailable checks say Unknown and offer Retry or Fix; they never render fake green.

## 6. Components and complete async/destructive states

Primary actions and settings/status rows use existing Material components, `primary`, current surface roles, 8-16dp radii, and at least 48dp targets.

- Default: readable label and semantic icon where useful.
- Pressed/hovered: Material state layer without layout movement.
- Focused: visible `primary` focus treatment and deterministic order.
- Disabled: labeled action plus nearby reason.
- Loading: bounded progress, live-region label, duplicate taps blocked.
- Empty: what is absent plus the next safe action.
- Error/Unknown: sanitized category plus Retry or direct Fix.
- Success: terminal text and icon, not green alone.
- Destructive: explicit object/scope, stronger confirmation for attachments/durable data, and safe Undo/rollback.

Update UI preserves signed preview, explicit consent, backup/rollback evidence, and system-installer handoff. Skill actions are labeled Update, History, and Rollback. No automatic/background install exists.

## 7. Motion and reduced motion

Motion communicates state change rather than decoration. Navigation/disclosure uses standard Material transitions. Streaming/status animation runs only while work is active. With `MediaQuery.disableAnimations`, repeating pulses, typing dots, and tool motion stop at a readable static frame. Motion is never the only completion/error signal.

## 8. Voice, content, localization, and privacy copy

Voice copy names idle, listening, stopping, transcribing, cancelled, or error; it shows truthful elapsed time, stop/cancel, sanitized route-specific errors, and a Settings action. Never invent transcription progress.

Actions use verbs and scope: Use local, Re-authorize, Check application update, Rollback extension. Privacy copy states when content leaves the device and what stays local. Search, diagnostics, history, and exports never index/reveal secret values, endpoints, credential references, raw prompts, tool payloads, or provider metadata. Chinese-first static strings remain current until generated localization is adopted.

## 9. Accessibility and anti-patterns

Use `Semantics` labels/state/value, bounded live regions, and TalkBack-readable focus order. Primary and icon-only actions are at least 48dp. Sheets, confirmations, search, composer, and CTAs remain scrollable/reachable at 320dp, landscape, 200% text, and with IME.

✓ Pair status color with icon and text.
✗ Never show a color-only state.

✓ Preserve local work across responsive/foldable transitions.
✗ Never recreate screens, restart checks, or place controls under a hinge.

✓ Label Update, History, Rollback, Retry, and destructive scope.
✗ Never hide consequential actions behind tooltip-only icons.

✓ Require explicit consent and expose recovery.
✗ Never silently install, upload, copy, activate network/JS, or mutate global policy from a one-call approval.

✓ Use progressive disclosure for advanced controls.
✗ Never return to one all-expanded Settings page or index secret values/endpoints.
