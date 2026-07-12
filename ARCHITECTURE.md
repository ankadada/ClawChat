# ClawChat Architecture

ClawChat is a local-first Android AI chat and agent application. Chat is the normal home; Settings and System Health are secondary maintenance surfaces.

## Runtime shape

- Flutter owns navigation, chat/session state, preferences, consent UI, diagnostics presentation, and update previews.
- `ChatProvider` routes each explicit per-session request either to the local model/tool flow or an authorized remote connector.
- `AgentService` runs the local agent loop through `LlmService` and `ToolRegistry`.
- Shell and workspace file operations cross the Kotlin MethodChannel into the embedded proot Alpine runtime.
- `SessionStorage` is authoritative for local chat history and recovery. Provider conversation identifiers and streaming frames are not persisted.
- `AppHttpClientRegistry` owns application transports and the runtime-derived fixed user agent.
- Signed app and extension updates use staged verification, explicit preview/consent, durable local evidence, and the Android system installer boundary.

## Trust and privacy boundaries

Credentials use platform-backed secret storage; ordinary preferences and exports contain opaque references only. External processing is per-session opt-in and requires configuration-bound consent. Diagnostics and run traces are local, sanitized, metadata-only, and never uploaded automatically. There is no mandatory account, cloud session sync, hosted control plane, background upload, or telemetry pipeline.

## Responsive shell

`flutter_app/lib/layout/foldable_layout.dart` interprets Android `DisplayFeature` geometry. Flat screens retain the adjustable dual-pane shell. Book posture separates list and detail/chat around the hinge. Tabletop posture keeps primary actions in the usable region selected with current IME insets. Stateful screens retain keys and providers across posture changes.

## Source-of-truth documents

- Visual and interaction contract: [`DESIGN.md`](DESIGN.md)
- Historical OpenClaw migration plan: [`docs/migrations/openclaw-to-clawchat.md`](docs/migrations/openclaw-to-clawchat.md)
- Product overview: [`README.md`](README.md)
- Runtime implementation: [`flutter_app/`](flutter_app/)

The migration archive is historical evidence, not an implementation specification. Current code and this document win if it conflicts with them.
