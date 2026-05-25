# ClawChat Backlog

## Multi-Session Parallel AI

Currently only one session can run AI at a time (single `_isSending` / `_agent` / `_cachedLlm` / `streamingText` on the singleton ChatProvider). To support multiple sessions generating responses concurrently, per-session agent state is needed.

Two approaches:
1. `Map<sessionId, AgentState>` inside ChatProvider — medium effort, keeps single provider.
2. Multiple ChatProvider instances — cleaner but requires DI/widget tree rework.

Considerations: API rate limits, ForegroundService notification multiplexing, error handling per session. Low priority until a real use case surfaces.
