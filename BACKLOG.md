# ClawChat Backlog

## Message Queue

When AI is generating a response (`_isSending = true`), new `sendMessage` calls are silently dropped. Add a pending message queue so user can type and send while AI is still responding — the next message fires automatically after the current response completes.

Scope: small. Add `List<_PendingMessage>` buffer in ChatProvider, dequeue in `sendMessage`'s finally block.

## Multi-Session Parallel AI

Currently only one session can run AI at a time (single `_isSending` / `_agent` / `_cachedLlm` / `streamingText` on the singleton ChatProvider). To support multiple sessions generating responses concurrently, per-session agent state is needed.

Two approaches:
1. `Map<sessionId, AgentState>` inside ChatProvider — medium effort, keeps single provider.
2. Multiple ChatProvider instances — cleaner but requires DI/widget tree rework.

Considerations: API rate limits, ForegroundService notification multiplexing, error handling per session. Low priority until a real use case surfaces.

## Configuration Import/Export

Currently only chat sessions can be exported/imported. API keys、Provider profiles、environment variables 存在 FlutterSecureStorage 中，卸载或重装 app 后全部丢失且无法恢复。

需要在 Settings 中添加配置的导入/导出功能：
- 导出：将 provider profiles（含 apiKey、baseUrl、model 等）和 env_vars 序列化为加密 JSON 文件，保存到用户选择的位置
- 导入：从文件读取并恢复所有配置
- 安全考虑：导出文件需要加密或至少提示用户妥善保管（含明文 API key）

Scope: medium. 涉及 PreferencesService 读取 + 文件选择器 + 加解密 + Settings UI 入口。
