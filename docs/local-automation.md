# 本地自动化、记忆可见性与工作流模板（v2.15.0 路线）

本文记录第二条产品增强路线的可用 MVP：**计划执行**、**记忆可见性**、**本地工作流模板**。
三者都以“本机状态 + 现有审批/同意路径”为前提，不引入新的自动执行、后台模型调用或网络下载。

## 1. 计划执行（scheduled tasks）

- 模型与存储：`flutter_app/lib/models/scheduled_task.dart`、`flutter_app/lib/services/scheduled_task_service.dart`。
  计划保存在 SharedPreferences 键 `clawchat_scheduled_tasks_v1`（最多 32 条，每条最多 20 条执行历史，间隔 15–1440 分钟）。
  计划只存 `taskId` 与调度元数据；任务内容仍留在既有的加密后台任务存储里，明文偏好文件里没有任务文本。
- 行为：创建 / 暂停 / 继续 / 删除、下次运行时间、失败次数与重试上限、成功与失败的历史记录。
- **不会自动执行**：`ScheduledTaskService` 没有执行或派发 API。到期只让计划出现在“待确认”，实际运行仍然走既有的后台任务中心（预览 → 批准 → 执行）与工具审批策略。
- 一次性计划跑完即结束；要再跑必须由用户显式选择新的时间。间隔计划按“计划时间”推进，不补跑错过的整段次数（避免长时间挂起后一次爆发多次执行）。
- UI：`flutter_app/lib/screens/scheduled_tasks_screen.dart`（任务中心右上角“计划执行”与 设置 → 数据管理 → 计划执行）。
  新建计划必须勾选“我确认：到期后需要我再次确认才会执行”。

## 2. 记忆可见性（memory）

- 事实列表：`MemoryService.listFacts()` 返回每条事实的文本、是否可信、以及不可信来源（`web` / `phone` / `mcp`）。
  设置 → 记忆管理为每条事实显示 `用户确认（可信）` 或 `来自 <source>`，删除按钮调用 `MemoryService.forgetFact(text)`，连同该事实的信任记录一起移除。
- 本轮用量：`MemoryService.memoryUsedInLastRun(sessionId)` 记录**最近一次真正注入提示词**的事实，顺序与来源与模型所见一致。
  聊天命令面板 →“本轮记忆”会显示这份快照与每条的信任状态；因为是运行快照，事后改开关或删记忆不会改写“那次回复用了什么”。
- 会话开关：全局开关保持原样；每个会话可单独开启/关闭（`MemoryService.setSessionEnabled`），
  当会话值与全局值一致时清除覆盖、回到“跟随全局”，因此旧设置的语义不变。`SessionMemoryToggleState` 把全局值、覆盖值与最终生效值分开显示。
- 会话覆盖保存在**加密应用私有存储**（`clawchat.memory_session_modes.v1`，带 sha256 信封校验），不再读写 guest 可写的
  `root/.clawchat_memory_sessions.json`；旧文件即使被 agent shell 改写也不会生效，只会被检测到并退休。
  存储读取失败、非 Map、schema 错误或校验和不符时按 **disabled 优先** 处理（所有会话先视为关闭），
  用户再次设置开关会重写一份合格式存储。
- 信任标志存储（`clawchat.memory_untrusted.v1`）同样 fail-closed：合法 JSON 但顶层不是 Map、键或值类型不对、
  未知来源名都会把整份存储标记为不可读，所有事实按不可信处理，且不会被静默“修复”。
- **不削弱既有规则**：不可信事实仍然进入 `Untrusted memories` 提示段与运行期 taint 集合；`memory_get` 仍按原始来源重新标记；
  信任存储读不到时仍然整体按不可信处理；本次改动只增加“看得见 + 删得掉”，没有新增放行路径。

## 3. 本地工作流模板（workflow templates）

- 模板目录：`flutter_app/lib/services/skill_template_catalog.dart` 内置 2 个本地模板：
  - `template.daily-work-summary` 每日工作总结（workspace 读写 + memory 读取，不访问网络）
  - `template.calendar-briefing` 日程提醒草稿（手机日历读取 + workspace 写入，标注隐私数据）
- 模板正文在应用内编译（`SkillTemplate.body`），**没有任何 URL 字段或远程下载**；
  安装写入 `workspace/skills/<id>/SKILL.md` 和受控的 `workspace/skills/<id>/skill.json` 清单，
  并把上一份包文件保留为 `.rollback`。
- **清单是唯一能力来源**：`SkillTemplateService.buildManifest()` 把模板声明（`workspace.read` / `workspace.write` /
  `memory.read` / `phone.calendar.read` / `web.read`）展开成 manifest 的 tools / filesystem / android / networkDomains / riskTier，
  并写入自校验的 sha256 摘要；`SkillService.scanSkills()` 按普通带清单技能读取，扫描到的能力快照与预览一致，
  清单被改动（摘要不符）或被削弱时该技能直接判为无效。
- 预览：`SkillTemplateService.preview()` 列出需要的权限、是否访问网络、会接触的隐私数据与风险说明；
  校验拒绝未知能力、超过 16 KiB 的正文、以及正文内含 `http(s)://` / `curl` / `wget` 的模板。
- 安装后**默认禁用**；启用必须通过既有的已安装技能同意流程（`prepareConsentForInstalledSkill` → `installPreparedSkill`，
  即设置里的技能同意对话框）记录 trust grant，`SkillTemplateService.setEnabled` 在没有当前 grant 时返回
  `template_consent_required`，不会出现“开关打开了但扫描仍禁用”的状态；正文或清单变化后 grant 立即失效，需要重新同意。
  可以一键回滚到上一版本包（正文 + 清单），回滚同样保持禁用。
- 运行期由既有 `SkillCapabilityPolicy` 执行：声明过的工具（如 `memory_get`）放行，未声明的工具
  （如 `bash`）返回 `skill_tool_undeclared`，`read_file`/`write_file` 仍是显式的
  `skill_filesystem_unenforceable` 拒绝，不会因为模板声明而变成可用的文件权限。
- UI：设置 → 技能与扩展 → 工作流模板（预览 / 安装 / 启用 / 回滚）。

## 边界与未完成

- 本路线没有改动 Workspace、分享面板、文件浏览器、MCP 启动、备份与 rootfs 读取路径。
- 计划不会在应用未运行或重启后自动恢复执行；`due()` 只是查询，重启后仍要用户在任务中心确认。
- 模板没有版本仓库/签名机制，只有“上一份包（正文 + 清单）”这一级回滚（MVP）。
- 升级首次启动若检测到旧的 guest 可写会话覆盖文件：不导入其内容、按 disabled 优先，并退休该文件；下一次启动回到全局设置。
- Android 侧本路线没有新增原生代码，因此没有对应的 JVM 测试；Flutter 侧测试见下。

## 测试

- `flutter_app/test/services/scheduled_task_service_test.dart`
- `flutter_app/test/services/memory_visibility_test.dart`（含信任存储 fail-closed、会话覆盖加密存储/guest 重写/损坏恢复）
- `flutter_app/test/services/skill_template_service_test.dart`
- `flutter_app/test/services/skill_template_pipeline_test.dart`（install → scan → consent/grant → load → capability policy 端到端）
- `flutter_app/test/screens/scheduled_tasks_screen_test.dart`
- `flutter_app/test/tool/skill_evals/`（host gate / runtime evidence；摘要见 `flutter_app/tool/skill_evals/runtime-evidence.json`）
