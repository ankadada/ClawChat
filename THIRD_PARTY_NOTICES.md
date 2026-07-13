# Third-party PRoot payload

ClawChat packages PRoot and talloc binaries so its Android runtime can start
without a separate Termux installation.

## Binary provenance

`scripts/fetch-proot-binaries.sh` restores the exact PRoot payload previously
published in the project's `v2.0.0` per-ABI APK assets. The asset names and
complete APK SHA-256 values pin the binary identity before any entry is read:

| ABI | Release asset | SHA-256 |
| --- | --- | --- |
| arm64-v8a | `OpenClaw-v2.0.0-arm64-v8a.apk` | `2e176888652afd51ffa02b3a63e667be188e5b0191ffccab1a935d72eb14a5f1` |
| armeabi-v7a | `OpenClaw-v2.0.0-armeabi-v7a.apk` | `159ba0486a4863f2d41228477e616261fc2a91e6449e7be62ca9900f80757de1` |
| x86_64 | `OpenClaw-v2.0.0-x86_64.apk` | `f52b64191e250b4d3a9d3285f47df4e163aa349e9f31384c9ce2a1b6621c33e1` |

The fetched files are staged, checked against the repository's exact 11-file
ABI/name matrix, structurally verified as ELF files, and only then installed in
`jniLibs`. A moving package-repository alias is not used.

## Upstream projects and licenses

- PRoot: <https://proot-me.github.io/>; GPL-2.0-or-later.
- talloc: <https://talloc.samba.org/>; LGPL-3.0-or-later.
- Termux packaging metadata and source recipes: <https://github.com/termux/termux-packages>.

ClawChat itself is distributed under GPL-3.0; see [LICENSE](LICENSE). When the
pinned binary payload is updated, update the named assets, digests, upstream
source/license references, and verifier expectations in the same change.
