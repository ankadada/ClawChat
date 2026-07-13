# Contributing to ClawChat

Thanks for helping improve ClawChat. This guide keeps contributions easy to review and safe for Android users.

## 前置条件

- Flutter SDK, matching the version used by CI when possible.
- Android SDK with platform tools.
- Android device or emulator running Android 10+.
- Git and a shell environment.

## 构建

From the repository root:

```bash
cd flutter_app
flutter pub get
flutter run
```

For release builds, use the canonical repository-root command. It fetches and
verifies every PRoot ABI payload before building, then verifies the APK archive:

```bash
bash scripts/build-apk.sh
```

The PRoot payload is a reviewed release dependency, pinned by release tag and
SHA-256 in `scripts/fetch-proot-binaries.sh`. Updating it requires one
coordinated review of the fetch pins, the verifier's ELF/dependency contract,
and the Android runtime loader paths. Gradle intentionally never fetches
binaries: a raw build from a clean checkout fails closed until the canonical
lane has populated the complete ABI matrix.

Do not add App Bundle build, artifact upload, or release attachment steps without
a verifier that proves the packaged base-module contents and bundletool delivery.
The supported release lane is APK-only.

## 代码风格

- Follow the existing Dart, Flutter, Kotlin, and shell patterns.
- Keep changes focused; avoid unrelated formatting or refactors.
- Prefer clear names and small, testable changes.
- Run `flutter analyze --no-fatal-infos` before submitting.

## 测试

All tests must pass before opening a PR:

```bash
cd flutter_app
flutter test
```

Add focused tests when changing shared logic, parsing, security-sensitive code, or user-visible behavior.

## PR 流程

1. Fork the repository.
2. Create a feature branch from `main`.
3. Make focused commits with clear messages.
4. Run analysis and tests.
5. Open a pull request with a summary, testing notes, and screenshots for UI changes.

## Issue 报告

When reporting an issue, include:

- What happened and what you expected.
- Steps to reproduce.
- Device model and Android version.
- ClawChat version or commit.
- API format and provider, if relevant.
- Logs or screenshots when available.

Please avoid posting API keys, tokens, private prompts, or sensitive files.
