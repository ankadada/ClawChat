# ClawChat Agent Rules

## Red Lines

### 1. NEVER install to user's device without explicit instruction

Any command that deploys to a real device (`flutter install`, `adb install`, `adb push`, etc.) is a **destructive operation** — it may uninstall the previous version and wipe all user data (API keys, provider profiles, environment variables stored in FlutterSecureStorage are irrecoverable after uninstall).

- "Verify the build works" = run `bash scripts/build-apk.sh` from the repository root and confirm its PRoot/APK gates pass. Do NOT install.
- "Check it compiles" = run `flutter analyze` + the canonical `bash scripts/build-apk.sh` release lane. Do NOT install.
- Even if the user says "install it", warn them that `flutter install` uninstalls the old version first, causing data loss. Suggest `adb install -r` instead.
- This rule exists because a previous incident wiped all configured API keys and environment variables by running `flutter install` without authorization.

### 2. Code review must include runtime scenario analysis

Static correctness (types, branches, logic) is not enough. Every review MUST include:

- **Background/foreground lifecycle**: Will this code behave correctly when the app is suspended by the OS? Do timers, timeouts, or streams break when the Dart event loop is paused?
- **Network interruption**: What happens if the connection drops mid-operation? Are retries safe? Do they waste attempts in unrecoverable states?
- **State consistency**: After resume/reconnect, is the accumulated state (buffers, counters, subscriptions) still valid?
- **Resource cleanup**: Are HTTP connections, streams, timers properly closed on error paths?

This rule exists because a `.timeout(60s)` on a stream passed code review but would have guaranteed failure whenever the app was backgrounded for over 60 seconds — the Dart Timer keeps ticking while the event loop is suspended.

## Build & Test

```bash
# Analyze (should have 0 errors/warnings; info-level lints are pre-existing)
cd flutter_app && flutter analyze

# Unit tests
cd flutter_app && flutter test test/services/llm_service_test.dart

# Build release APK (verify only — do NOT install)
bash scripts/build-apk.sh
```

## Architecture Notes

- Android only (no iOS)
- API keys and provider profiles are stored in FlutterSecureStorage (encrypted, excluded from Android backup, irrecoverable after uninstall)
- LLM streaming uses SSE over HTTP (`http` package), with `_resilientSseDataStream()` providing unified retry/reconnect
- Background persistence: Android ForegroundService + PARTIAL_WAKE_LOCK via AgentTaskService
