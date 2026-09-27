# v2.18 Android 原生能力：AND-1..AND-6 实现 / 缺口矩阵

对应 `docs/android-roadmap.md` §5。本表记录 **v2.18.0+18 交付时的真实状态**：
每一条是「已有实现 / 本版补齐 / 仍未验证」，不是规划。凡是需要真机才能证明的验收项
（§5 表格里的「验收方式」列）一律标 **NOT RUN**——开发者不接触设备，只有 tester 真机执行后才可改为 PASS。

## 1. 总览

| 编号 | 工作项 | 代码状态 | 真机验收 |
| --- | --- | --- | --- |
| AND-1 | 分享入站 | 已具备（前序版本），本版未改语义 | NOT RUN |
| AND-2 | 分享出站 | 已具备（前序版本），本版未改语义 | NOT RUN |
| AND-3 | 文件与 SAF | 已具备 + 本版补低存储前置检查 | NOT RUN（2.14 SAF 遗留项仍未收口） |
| AND-4 | 通知 | **本版补齐渠道分类**，隐私/动作/空文案沿用既有实现 | NOT RUN |
| AND-5 | 权限 broker | **本版补齐永久拒绝判定与引导**，请求限额/撤销重查沿用既有实现 | NOT RUN |
| AND-6 | 存储与清理 | **本版补齐统一低存储前置检查**，配额与清理沿用既有实现 | NOT RUN |

基线：`c3aa0b4`（v2.17.0+17）。本版不重写既有分享/通知/备份管线，只补真实缺口。

## 2. AND-1 分享入站（ACTION_SEND / ACTION_SEND_MULTIPLE）

| 能力 | 位置 | 状态 |
| --- | --- | --- |
| `ACTION_SEND` / `ACTION_SEND_MULTIPLE` 入口、`EXTRA_TEXT` / `EXTRA_STREAM` / `clipData` | `MainActivity.kt` `handleShareIntent`(`ACTION_SEND*` 判定 + URI 收集) | 已有 |
| 文本 / 主题 / URI 数量上限（64 KB / 1 KB / 64） | `SharedIntentLimits.kt` | 已有 |
| 缓存配额（64 MiB / 64 文件）与去重 | `SharedIntentCacheQuota.kt`、`SharedIntentCacheWriter.kt` | 已有 |
| 来源不可读 → fail-closed 且用户可读反馈 | 原生写入失败 + `SharedContent.errors` → `SharedContentPreparer` 生成 feedback（`hasFeedback`） | 已有 |
| Dart 侧二次截断与错误上界 | `lib/services/shared_content.dart`（`maxTextBytes` 64 KB、`maxSubjectBytes` 1 KB、`maxImages` 9、`maxErrors` 32） | 已有 |

**本版未做**：语义未放宽，也没有新增入站能力。**缺口**：浏览器 / 相册 / 微信 / 文件管理器四来源真机矩阵、
超限与不可读来源的真机提示仍未执行（NOT RUN）。

证据：`SharedIntentLimitsTest.kt`、`SharedIntentCacheWriterTest.kt`、`SharedIntentCacheQuotaTest.kt`、
`test/services/shared_content_test.dart`（截断、上限、errors-only 反馈、图片预算）。

## 3. AND-2 分享出站

| 能力 | 位置 | 状态 |
| --- | --- | --- |
| 对话 / 文本经系统分享面板发出 | `MainActivity.kt` 分享 `Intent.ACTION_SEND` | 已有 |
| 长文本上限与可见提示（8000 字符 → 提示「已截断…可用保存到工作区」） | `lib/services/share_action.dart` | 已有 |
| 原生侧文本 / 主题 / URI 上限与去重语义 | `SharedIntentLimits.kt`、`SharedContentLimits` | 已有 |

**缺口**：大文本与多图分享的真机表现（不崩溃 / 不截断关键内容）NOT RUN。

证据：`test/services/share_action_test.dart`、`test/services/shared_content_test.dart`。

## 4. AND-3 文件与 SAF

| 能力 | 位置 | 状态 |
| --- | --- | --- |
| 系统文件选择器导入（技能包：URL / 本地路径） | `SkillService.prepareSkillFromUrl` / `prepareSkillFromLocalPath` | 已有 |
| 多目标备份（每个目标独立结果，任一失败不谎报成功） | `lib/services/backup_run_service.dart`、`backup_run_service_test.dart` | 已有 |
| 低存储前置检查（本版新增） | `lib/services/storage_budget.dart` → `BackupRunService.run` 前置 | **本版新增** |
| 工作区范围规则不放宽 | `AgentBashStorageBindTest.kt`、`MANAGE_EXTERNAL_STORAGE` 仅用户发起流程（`MainActivity` 设置跳转、`ProcessManager` 绑定测试） | 已有，本版未改 |
| SAF 目录授权被撤销 / 选择器返回空 → 明确提示、不静默丢数据 | 备份目标写入失败 → `failure` + 错误文案；取消 → `cancelled` 且保留本地包 | 已有 |

**缺口**：SAF 真机验证（2.14 遗留项）仍未收口 → NOT RUN。
证据：`test/services/backup_run_service_test.dart`（成功/失败/取消/低存储/未知空间）、
`test/services/skill_remote_import_security_test.dart`（低存储在任何 staging 前失败）。

## 5. AND-4 通知

| 能力 | 位置 | 状态 |
| --- | --- | --- |
| 渠道分类：状态（静默）/ 待确认（需用户动作，高优先级）/ 完成 | `NotificationChannelCatalog.kt`（**本版新增**），`MainActivity` 建渠道、`AgentTaskService` 按类选渠道 | **本版新增** |
| 锁屏隐私（正文只进 private，锁屏只见通用文案） | `NotificationPrivacy.kt` + 每个通知 `VISIBILITY_PRIVATE` + `publicVersion` | 已有，本版保持 |
| 通知动作（Stop / 打开会话 / 审批 同意·拒绝） | `AgentTaskService`（`ACTION_STOP_AGENT`、`openPendingIntent`、`approvalPendingIntent`） | 已有 |
| 空通知处理（空完成文案 → 「点击查看回复」） | `AgentTaskService.showCompletionNotification` | 已有 |
| 免打扰 / 渠道被关闭时的可见性判定 | `canShowApprovalNotification`（读取**待确认渠道**，本版随之更新） | 本版修正渠道来源 |
| 锁屏文案在携带凭据的 destination 下仍通用 | `ApprovalNotificationText.publicCopy` + 新 Kotlin 用例（`api_key=`、`Bearer`、命令、电话号码） | 本版补证据 |
| 解锁正文不含应用已配置的凭据 | 新增 `ChatProvider.maskConfiguredSecretsForNotification`（env vars + 各 Provider API Key），通知预览进入原生之前掩码 | 本版修复 + `chat_provider_test` 证据用例 |
| 每个含用户内容的通知都 `VISIBILITY_PRIVATE` + `publicVersion` | 源码守卫逐 builder 校验；终端前台通知补 `VISIBILITY_PRIVATE`；无 `setBypassDnd(true)`/`setSound(` | `android_notification_privacy_source_test` |
| 多会话通知互不覆盖 | 抽出 `AgentNotificationIds`（会话/完成 id 稳定且不碰撞），完成通知不覆盖运行中通知 | `AgentNotificationIdsTest` |

**修复动机（真实缺口）**：审批提示此前与状态更新共用静默渠道（`IMPORTANCE_LOW`），
用户可能在 agent 等待确认时完全收不到声音/震动提示。现在审批与后台任务复查走
`clawchat_approval_v1`（`IMPORTANCE_HIGH`），进度类通知留在 `clawchat_status_v2`。

**缺口**：锁屏 / 免打扰 / 多会话并行 / 权限关闭的真机通知矩阵 NOT RUN；携带凭据的审批 destination 在真机锁屏/解锁下的实际渲染也需真机确认。
证据：`NotificationChannelCatalogTest.kt`（渠道互异、静默 vs 告警、无 IMPORTANCE_NONE、全部锁屏私有、
按需选渠道）、`NotificationPrivacyTest.kt`、`ToolApprovalNotificationStateTest.kt`（含携带凭据 destination 的锁屏用例）、
`android_notification_privacy_source_test.dart`（逐 builder 的 private/public、完成通知可点击、每会话独立 id、
无免打扰绕过、终端通知无用户内容）、`AgentNotificationIdsTest.kt`、`chat_provider_test`（通知预览掩码证据）。

## 6. AND-5 权限 broker

| 能力 | 位置 | 状态 |
| --- | --- | --- |
| 统一分类：已授权 / 已请求（一次）/ **永久拒绝** | `PermissionRequestGuard.classify`（`PermissionAskResult`，**本版新增**） | **本版新增** |
| 每个权限每个 Activity 生命周期只弹一次系统框 | `PermissionRequestGuard.shouldRequest`、`PhoneIntentManager.ensurePermission` | 已有，本版保留 |
| 系统不再弹框时给出「去设置」引导而不是谎称会再弹 | `PhoneIntentManager.permissionError` → `permission_permanently_denied` + `settingsRequired`；Dart `phone_tools._augmentPermissionResult` | **本版新增** |
| 撤销后重新用工具 → 重新检查实时授权并再次请求 | `ensurePermission` 每次调用都 `checkSelfPermission` | 已有（本版补测试） |
| 工具卡片一键打开应用权限设置 | `lib/widgets/tool_call_card.dart`（`permission_required` 与 `permission_permanently_denied` 都出现按钮）、`NativeBridge.openAppDetailsSettings` | 本版扩展错误码 |
| 覆盖日历、短信、联系人、通知 | `insertCalendarEvent` / `listCalendarEvents` / `listSms` / `getSms` / `listContacts` / `callPhone` / `sendSms`；`POST_NOTIFICATIONS` 请求与可见性判定；六个权限点均带中文标签与「系统设置」指引（表驱动用例） | 已有，本版统一错误路径 + 补测试 |
| 存储权限 | SAF 不需要运行时存储权限；`MANAGE_EXTERNAL_STORAGE` 只在用户发起的设置跳转中使用，不绑定 agent bash | 已有，本版未改 |
| 请求与 run 绑定 | `PhoneIntentManager.permissionError` 在参数带 `runAttemptId` 时回传；工具调用本身属于 run（`ToolApprovalRequest.runAttemptId`）。Dart 各 action 只白名单转发原生参数，故 run 绑定停在工具/审批层，不随参数穿透 | 部分（见缺口） |

**缺口**：
1. 权限矩阵真机测试（同意 / 拒绝 / 永久拒绝 / 系统设置撤销）NOT RUN。
2. 权限点表的覆盖是 Dart 侧映射 + Kotlin 分类；真机上各 ROM 的弹框与 rationale 行为仍需真机矩阵确认。
3. `permission_permanently_denied` 的判定依赖 `shouldShowRequestPermissionRationale`，
   部分厂商 ROM 行为有差异，只有真机能确认（NOT RUN）。
4. Android 12+ 「仅本次允许」的近似位置/一次性权限不在覆盖范围（工具未申请此类权限）。

证据：`PermissionRequestGuardTest.kt`（7 例，含「撤销后重新可请求」「已请求且无 rationale → 永久拒绝」）、
`test/services/tools/phone_tools_test.dart`（稳定错误码 + 中文引导 + 永久拒绝文案 + 六个权限点的表驱动覆盖）、
`test/widgets/tool_call_card_test.dart`（两种错误码都出现 Fix 按钮，成功结果不出现）。

## 7. AND-6 存储与清理

| 能力 | 位置 | 状态 |
| --- | --- | --- |
| 统一低存储前置检查（64 MiB 基准 + 调用方额外需求） | `lib/services/storage_budget.dart`（**本版新增**） | **本版新增** |
| 备份前检查：空间不足则不生成包、不写任何目标，所有目标记失败并给出可执行文案 | `BackupRunService.run` | **本版新增** |
| 技能包导入（URL / 本地）前检查：空间不足则不执行任何 staging 命令 | `SkillService.prepareSkillFromUrl` / `prepareSkillFromLocalPath` | **本版新增** |
| 分享缓存配额（64 MiB / 64 文件）与去重 | `SharedIntentCacheQuota.kt` | 已有 |
| 命令 staging 清理 | `CommandCleanupCoordinator`（清理 job + 清理协调） | 已有 |
| 更新 APK staging 清理与校验 | `VerifiedApkUpdateTest.kt` 覆盖的更新路径 | 已有 |
| 无法读取可用空间时不阻塞（避免误判为满盘），写入自身错误仍然可见 | `StorageBudgetReason.unknown` | **本版新增** |
| 配置导入（设置 → 数据与恢复）50 MiB 硬上限 | `ConfigExportService.maxImportBytes` + `configImportSizeError`：按**选择器声明大小**在读取/复制/staging/解析前拦截；`BoundedFileReader` 二次按字节数复查；`importConfig`/`previewImport` 再兜底；超限/不可读均有含文件名与大小的可执行文案 | **本版新增** |
| 备份包与目标文件原子发布（同目录 `.part` + flush + rename，失败必删） | `lib/services/atomic_file_write.dart`，`FileBackupPackageStore.save` 与 `BackupDestination.folder` 均使用；暂存失败不再谎称「已保留本地包」 | **本版新增** |

**配置导入上限证据（本机可验证）**：`config_export_service_test`（上限值/边界/消息内容/fail-closed/超限载荷不写任何偏好）、`settings_config_import_limit_test`（Widget：60 MiB 选择 → 文案含文件名+60.0MB+上限 50.0MB，零 `stagePickedContentUri` 调用；无路径 → 可执行提示；恰好 50 MiB → 不被大小守卫拒绝且零 staging）。

**原子发布证据（本机可验证）**：写一半失败 → 目标路径不存在且目录为空；rename 失败 → 无目标文件、无 `.part`；暂存失败 → `localPackagePath` 为空且不报「保留」；多目标真实目录一成功一失败 → 全树无 `.part` 残留（`backup_run_service_test`）。

**决策**：未知空间**不** fail-closed。存储不是安全边界，误报满盘会让导入/备份在正常设备上直接失败；
真正的写入失败仍会沿既有路径给出错误，不存在静默丢数据。

**缺口**：磁盘接近满时导入 / 备份 / 分享的真机行为（NOT RUN）。
证据：`test/services/storage_budget_test.dart`（阈值、额外需求、未知、读取异常、文案格式）、
`test/services/backup_run_service_test.dart`（满盘不建包不写目标、未知空间照常完成）、
`test/services/skill_remote_import_security_test.dart`（满盘在任何 staging 前失败）。

## 7.1 真机复现修复（第二轮，UI 与发送路径）

| 问题 | 修复 | 证据 |
| --- | --- | --- |
| 紧凑态（窄屏 / 大字号）导出配置弹窗主按钮命中区不完整 | 抽出 `lib/widgets/export_config_dialog.dart`：窄屏或 >1.3× 字号时主按钮移入弹窗正文并**全宽**显示（≥48dp、文案不截断），带独立 `Semantics` 节点；宽屏仍使用 action row | `test/widgets/export_config_dialog_test.dart`（320dp 窄屏、1.8× 字号角点点击、语义断言、宽屏对照） |
| 远程会话带工作区附件被静默降级 | `_sendMessage` 在调用远程发送前 fail-closed：`workspaceImports` 非空即返回可执行提示、`acceptance=false`、零远程请求、零 ACK/丢弃；`chat_screen` 保留草稿与 receipt | `remote_agent_chat_provider_test`（无请求/无孤儿 receipt/纯文本仍可发）、`chat_attachment_receipt_lifecycle_source_test` |
| 发送被拒时静默拦截且丢草稿 | `sendMessageWithWorkspaceImports` 返回**接受结果**（只有持久化接受或入队才为 `true`）；被拒时保留草稿与附件，显示原因并（缺凭据时）给「去设置」；不自动重跑 | `chat_provider_test`（拒绝返回 false、接受返回 true、失败 run 后仍可显式重发、入队视为接受）、`chat_oversized_pick_test`（草稿保留 + 提示 + 入口） |
| 迟到的 run 续作在 `dispose()` 之后触发 ChangeNotifier 断言 | `notifyListeners()` 在 dispose 后静默丢弃；`dispose()` 幂等 | `chat_provider_test`（dispose 后通知不抛、二次 dispose 无害） |

**最新包真机复核**：大字体 + 窄屏弹窗主按钮、无凭据发送后的提示与设置跳转、拒绝后草稿保留均 **PASS**；失败 / 中断会话显式重发在同一 hash 的前一轮实测 **PASS**。锁屏实际渲染仍 **NOT RUN**。

## 8. 本版不做（与 §5.2 一致）

- 不新增与功能无关的权限；`MANAGE_EXTERNAL_STORAGE` 仍只用于用户发起的流程。
- 不做通知监听、无障碍、悬浮窗默认开启。
- 不做 Play 专属 API 与 Play 审核专项。
- 不引入端侧大模型（与 §1.3 一致）。

## 9. 真机验证清单（当前包状态）

验收对象：v2.18.0+18，sha256 `f0e94b00bad0604413e371bdd9265275a99311427af8e947f9f9aff354b5dd07`。以下状态只引用该 hash 的真机报告；同 hash 前一轮证据明确标注“前一轮”。

1. **AND-1 分享入站：NOT RUN** — 最新轮未覆盖浏览器、相册、微信、文件管理器四来源的完整文本 / 单图 / 多图矩阵。
2. **AND-2 分享出站：NOT RUN** — 最新轮未覆盖大文本与多图出站完整矩阵。
3. **AND-3 SAF：PARTIAL** — 配置导入 60 MiB 硬上限、文件名 / 实际大小 / 50.0 MB 文案与无残留 **PASS**；完整 SAF 遗留、多目标备份和目录撤销路径未全跑。
4. **AND-4 通知：PARTIAL** — 通知关闭、DND 新通知静音、多会话分组与私有 publicVersion **PASS**；锁屏实际渲染未跑。
5. **AND-5 权限：PARTIAL** — 同 hash 前一轮联系人 / 短信拒绝与永久拒绝有证据；本轮电话 / 发短信、设置内撤销未跑。
6. **AND-6 存储：NOT RUN** — 接近满盘和真机备份失败 / 取消注入未跑；代码侧 `.part` + 原子 rename + finally 清理有单测证据。
7. **第二轮修复：PARTIAL** — 窄屏大字导出按钮、无凭据草稿 / 去设置、配置导入上限 **PASS**；通用 SAF 大文件缓存、锁屏敏感内容未跑。
8. **回归：PASS** — v2.17 journal 与 v2.16 workspace/file-browser 在最新包通过。
9. **远程 workspace receipt：NOT RUN** — 当前 ROM 的附件选择器无法生成 receipt；代码测试覆盖发送前拒绝、零请求、零 ACK/丢弃与草稿保留。

产物与哈希见交付报告（release APK 的 sha256 与 `versionName` / `versionCode`）。
