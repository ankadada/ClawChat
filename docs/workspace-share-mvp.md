# Workspace, share workflow, and file browser

Status: all three pieces of the first route are implemented - workspace
foundation, the share-sheet workflow, and the file browser MVP.

## 1. Workspace foundation (shipped)

A workspace is a named view of the agent's existing tree, not a new storage
location: agent commands already run with /root/workspace as their working
directory, so the default workspace root is exactly that path.

- lib/models/workspace.dart - WorkspaceMetadata (id, name, rootPath,
  timestamps, flat attributes extension point). Scope rules: rootPath must be
  /root/workspace or below it, paths are normalized (no traversal, no empty
  segments, NUL rejected) and containsPath / relativePathOf answer scope
  questions before any native call. sanitizeFileSegment produces the
  filesystem-safe names used when saving.
- lib/services/preferences_service.dart - persistence in SharedPreferences under
  the workspaces and active_workspace_id keys. A fresh or corrupt store
  materializes the default workspace; a dangling active id falls back to the
  default; the default workspace cannot be deleted.
- ChatSession.workspaceId (nullable) links a session to a workspace. Sessions
  written before this change have no id and resolve through
  PreferencesService.workspaceForSession, so old data keeps working. New
  sessions are stamped with the active workspace in ChatProvider.createSession.
- ChatProvider exposes workspaces, activeWorkspace, workspaceById,
  workspaceForSession, setActiveWorkspace, createWorkspace, renameWorkspace.
- Extension points for the other routes: attributes (flat JSON, bounded) plus the
  fixed layout inside the root (skills, shared, and anything a later route adds).

## 2. Share workflow (shipped)

Entry point is the existing share Intent path (MainActivity -> NativeBridge share
callback -> chat_screen._handleSharedContent). The existing bounds, import
receipts, dedupe and provenance are untouched; what is new is the action chooser
between "prepare" and "do something":

- lib/services/share_action.dart - pure planner. Kinds: summarize, extractTodos,
  saveToWorkspace, draftOnly. It builds the prompt text, truncates over-long
  content with a visible notice, and computes the save path
  (<workspace>/shared/<timestamp>-<sanitized subject>.md, always inside the
  workspace root, never overwriting another share).
- lib/widgets/share_action_sheet.dart - preview (subject, text excerpt, image
  count, import warnings), optional workspace picker, one row per action, and an
  explicit consent line: the two agent actions send content to the configured
  model, save/draft stay local.
- chat_screen executes the choice: agent actions stage the prompt and send it
  through ChatProvider.sendMessage only when a provider profile exists
  (otherwise the text stays in the composer with a notice); save writes through
  NativeBridge.writeRootfsFile scoped to the workspace root and offers an Undo
  that deletes the same path through the same scope. Dismissing the sheet
  discards the prepared attachments.

## 3. File browser (shipped)

- Kotlin: RootfsDirectoryLister is a pure, JVM-tested object. It resolves the
  guest path with exactly the scoped-API rules (normalizeRootfsVirtualPath +
  granted-scope containment + a real rootfs root + containment after
  normalization), rejects a symlinked component on the way down, requires the
  target to be a real directory, lists children with
  Files.readAttributes(..., NOFOLLOW_LINKS) and reports a link as a link instead
  of a directory to descend into. Results are sorted directories-first and paged
  (200 by default, 500 hard cap, 4096 scanned) with an explicit truncated flag.
  BootstrapManager.listRootfsDirectory is a thin wrapper and MainActivity serves
  it as the listRootfsDirectory platform call.
- Dart: NativeBridge.listRootfsDirectory plus
  models/workspace_file.dart (entry, listing, preview) and
  services/workspace_file_service.dart. The service refuses any path outside the
  workspace before the native call, always passes the workspace root as the only
  granted scope, caps text previews at 64 KiB and image previews at 2 MiB,
  refuses binary payloads, and allows file deletes only (a directory or a link is
  refused with an explicit reason). Every failure is a WorkspaceFileException
  with a user-facing message.
- UI: screens/workspace_browser_screen.dart - breadcrumb, directories first,
  size and modified time per row, preview sheet with SelectableText or
  InteractiveViewer, explicit "copy path" (clipboard only on tap), "send to
  current session" (returns the guest-path reference to the composer) and delete
  behind a dialog that names the file, its location and the workspace, states
  whether the deletion can be undone, and offers Undo for text files by writing
  the same content back through the same scope. Loading, empty, error (with
  Retry and a way back to the workspace root) and link states are all explicit.
  The entry point is the chat screen command surface ("工作区与工具").
## 3b. Descriptor-relative file operations (final review fixes)

The first browser cut still resolved paths in Kotlin (stat/list/delete by
pathname), which the guest that writes the same tree can swap between the check
and the use. Final state:

- android/app/src/main/cpp/rootfs_browser_io.cpp walks every component with
  openat(O_DIRECTORY | O_NOFOLLOW), verifies the opened directory identity,
  lists with fdopendir + fstatat(AT_SYMLINK_NOFOLLOW) (a link is reported as a
  link and never as a descendable directory), deletes through the parent fd with
  unlinkat after a regular single-link check, and writes through the parent fd
  with O_CREAT | O_EXCL | O_NOFOLLOW (never overwriting).
- SecureImportNative.listRootfsDirectoryBounded / deleteRootfsFileBounded /
  writeRootfsFileBounded expose it; BootstrapManager.listRootfsDirectory keeps
  only the scope policy, deleteRootfsFile and writeRootfsFile go through the
  broker, and reads use the existing bounded byte broker (readRootfsFileBytes),
  so list/read/write/delete are all descriptor-relative.
- The share write uses CREATE_NEW: a name that is already taken is refused by
  the broker and the next candidate is tried, so a save never overwrites.
- Tests: rootfs_browser_io_host_test.cpp (executed by
  test/services/rootfs_browser_io_host_test.dart) runs the real walk, including a
  thread that keeps swapping a browsed parent for a symlink; the JVM test covers
  the scope policy and fail-closed behaviour, and the source guard pins the wiring.

## 3c. Share sheet workspace binding and unique names

- The session, the save scope and the undo scope all use the workspace the user
  picked in the sheet: ChatProvider.createSession(workspaceId:) stamps it and
  _runShareAction passes that workspace explicitly instead of reading the active
  one (which no longer changes as a side effect of sharing).
- Saved shares use <yyyyMMdd-HHmmssSSS>-<4 hex>-<subject>.md plus two retry
  candidates, and the broker enforces CREATE_NEW, so two shares of the same
  subject in the same millisecond still produce two files.

## Known boundary: 外部分享来源

- 分享导入只接受 ContentResolver 能读取的来源（content:// 形式的 URI，以及发送方自身可读的 file:// 路径）。普通 ACTION_SEND 的 file:// 图片受 scoped storage 限制：发送方通常没有给接收应用读授权，openInputStream 会以 EACCES 失败。
- 该情况保持 fail-closed：不读取任意路径、不放宽 scope。UI 通过 SharedIntentLimits.unreadableSharedStreamMessage 明确提示"发送方没有授予读取权限，请改用系统文件选择器，或从支持 content:// 分享的应用重试"。
- 需要本地文件时，请通过应用内选择器（导入技能 / 从本地更新 等）拿到应用可读的副本，而不是绕过权限按路径直读。

## 4. Verification

Scoped to the files in this change (the repository currently does not compile
app-wide because of an unrelated in-flight route editing
lib/screens/settings_screen.dart):

    flutter test test/services/rootfs_browser_io_host_test.dart \
      test/providers/chat_provider_workspace_test.dart \
      test/models/workspace_test.dart \
      test/services/workspace_preferences_test.dart \
      test/services/share_action_test.dart \
      test/widgets/share_action_sheet_test.dart \
      test/services/workspace_file_service_test.dart \
      test/screens/workspace_browser_screen_test.dart \
      test/services/workspace_browser_source_test.dart \
      test/models/chat_models_test.dart \
      test/services/session_storage_test.dart \
      test/services/shared_content_test.dart
    flutter analyze lib/models/workspace.dart lib/models/workspace_file.dart \
      lib/services/share_action.dart lib/services/workspace_file_service.dart \
      lib/services/preferences_service.dart lib/providers/chat_provider.dart \
      lib/screens/chat_screen.dart lib/screens/workspace_browser_screen.dart \
      lib/widgets/share_action_sheet.dart
    cd android && ./gradlew :app:testDebugUnitTest   # includes RootfsDirectoryListerTest
