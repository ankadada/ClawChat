---
name: xds-skills
description: >
  代理用户调用 AI-XDS 平台的所有公开 skill，覆盖 TapDB 运营数据分析（DAU/留存/付费/ARPU/LTV/买量
  ROI/广告变现）、客服工单与微信支付投诉查询、中英互译（含术语表）、玩家日志与角色 ID/心动 ID
  互查、SDK 数据（订单/退款/支付回调/账号信息/登录/设备/绑定记录）。
  触发关键词：TapDB、DAU、MAU、留存、付费、收入、ARPU、LTV、ROI、ROAS、运营数据、买量、广告投放、
  玩家日志、埋点日志、身份互查、ID 互查、角色 ID、心动 ID、
  订单、退款、支付回调、通知任务、账号信息、实名信息、登录记录、设备记录、绑定记录、
  工单、投诉、客服工单、工单处理记录、微信支付投诉、投诉处理状态、聊天监控
  翻译、舆情。
version: "0.1.9"
---

# XDS Skills

> Skill 版本：v2026.0703.01

通过 AI-XDS 的 `/open-skills` HTTP 接口调用平台所有公开 skill。

## TL;DR

```bash
# 1. 看有哪些 skill
python3 <SKILL_DIR>/scripts/skills.py list

# 2. 拿目标 skill 的完整说明
python3 <SKILL_DIR>/scripts/skills.py get xds-data

# 2b. 需要确认项目时，统一用 xds-user-auth，不要借用业务数据分析 skill
python3 <SKILL_DIR>/scripts/skills.py get xds-user-auth
# 先 list 拿到全量项目，再根据用户原话挑出 id，最后 use <id>
python3 <SKILL_DIR>/scripts/skills.py exec \
  --skill xds-user-auth \
  --command 'list'
python3 <SKILL_DIR>/scripts/skills.py exec \
  --skill xds-user-auth \
  --command 'use 17'

# 3a. （按需）SKILL.md 提到 references/xxx.md 或 assets/xxx.md 时，按需拉取
python3 <SKILL_DIR>/scripts/skills.py files tapdb-data-analysis
python3 <SKILL_DIR>/scripts/skills.py files tapdb-data-analysis references/sql_schema_guide.md

# 3b. （按需）exec sync_skills 后想读项目 KB（如 tapdb 的项目知识库），用 kb
python3 <SKILL_DIR>/scripts/skills.py kb tapdb-data-analysis 123
python3 <SKILL_DIR>/scripts/skills.py kb tapdb-data-analysis 123 'abc 5/gacha_recruitment.md'

# 4. 按 step 2/3 的说明拼命令，让平台执行
#    每次 exec 都带上 --user-query（用户原话）和 --intent（你理解的诉求）
python3 <SKILL_DIR>/scripts/skills.py exec \
  --skill xds-user-auth \
  --command 'use 17' \
  --user-query '查下铃兰最近7天DAU' \
  --intent '用户选定铃兰项目以便后续查 DAU'
```

每条命令的 stdout 都是 JSON。

## 何时使用本 skill

只要用户的请求落在下面任何一类：

- **TapDB 运营数据**：DAU / WAU / MAU / 留存 / 付费 / 收入 / ARPU / ARPPU / LTV / 版本对比 / 卡池效果 / 买量 ROI / 广告变现（monet）
- **客服与投诉**：工单查询 / 工单处理记录 / 微信支付投诉 / 投诉处理状态
- **翻译**：中英互译 / 术语表
- **玩家与账号**：玩家日志 / 埋点 / 角色 ID ↔ 心动 ID 互查
- **SDK 数据**：订单 / 退款 / 支付回调 / 通知任务 / 账号信息 / 实名信息 / 登录 / 设备 / 绑定
- **项目舆情分析**：围绕指定项目、关键词和时间范围分析 TapTap、B站、贴吧等社区反馈，输出情绪分布、主题归因、负面焦点、玩家画像交叉和可下载报告

不确定能不能匹配？**直接 `list` 看一眼**——成本很低（一次 GET）。

## 运行前准备

```bash
export XDS_AGENT_TOKEN="your-token"

# XDS_AGENT_URL 不设置时默认指向 https://ai-xds.tapdb.net；本地开发再覆盖：
# export XDS_AGENT_URL="http://127.0.0.1:8080"
```

`XDS_AGENT_TOKEN` 是用户的 Bearer token，必填。`XDS_AGENT_URL` 是平台地址，默认走线上。

不知道 token 怎么拿？让用户打开 `<XDS_AGENT_URL>/token`（把 `<XDS_AGENT_URL>` 换成当前配置的值，
未设置时才是 https://ai-xds.tapdb.net），按页面指引获取；页面会直接给出 `export XDS_AGENT_TOKEN="..."`
一行，复制配置即可。缺 token 时脚本报错里已带上拼好的完整地址，照抄给用户即可。

## 工作流程

### Step 1: `list` — 列出可用 skill

```bash
python3 <SKILL_DIR>/scripts/skills.py list
```

返回：

```json
{"skills": [
  {"name": "tapdb-data-analysis", "description": "...", "requires_project": false},
  {"name": "xds-translate", "description": "...", "requires_project": false}
]}
```

- 不带 `--app-id` 时只显示 `requires_project=false` 的 skill。
- 用户已经指定了项目(或上一步 `xds-user-auth use <id>` 选好了 id),加 `--app-id 12345`
  会显示更多 skill。

按 `description` 选最匹配用户意图的那个 skill 名。

### Step 2: `get` — 拉 SKILL.md 全文

```bash
python3 <SKILL_DIR>/scripts/skills.py get tapdb-data-analysis
```

返回：

```json
{
  "name": "tapdb-data-analysis",
  "skill_md": "---\nname: tapdb-data-analysis\n...\n# TapDB 数据分析\n\n## 工作流程\n...",
  "requires_project": false,
  "skill_dir_placeholder": "<SKILL_DIR>"
}
```

`skill_md` 是 skill 的**真正说明**——里面有子命令、参数格式、业务规则。
**完整读完再继续**，不要凭空想象命令。

舆情分析对应 `xds-sentiment-analysis`，属于 `requires_project=false`——**不需要先选择项目**。
执行 `analyze` 时必须传 `--kb-slug`（如 `ssrpg` / `torchlight`），slug 由 agent 根据用户输入
按 KB 里的 `display_name` + `aliases` 自行推断，不要让用户去查具体 slug。

```bash
python3 <SKILL_DIR>/scripts/skills.py get xds-sentiment-analysis
```

### Step 2.5 (按需): `files` — 拉 SKILL.md 引用的延伸文档

很多 skill 把细节规则放在 `references/` 或 `assets/` 子目录里（见 SKILL.md 里
形如 `references/sql_schema_guide.md`、`assets/report_template.md` 的字样）。
这些文件在平台 server 端，远端无法直接 `read_file`，必须通过本接口拉。

**先列清单**：

```bash
python3 <SKILL_DIR>/scripts/skills.py files tapdb-data-analysis
```

返回：

```json
{
  "name": "tapdb-data-analysis",
  "files": [
    {"path": "assets/report_template.md", "size": 1234, "kind": "asset"},
    {"path": "references/anomaly_checklist.md", "size": 567, "kind": "reference"},
    {"path": "references/sql_schema_guide.md", "size": 28910, "kind": "reference"}
  ]
}
```

**再按需读**（路径就用 list 返回里的 `path`，不要拼绝对路径）：

```bash
python3 <SKILL_DIR>/scripts/skills.py files tapdb-data-analysis references/sql_schema_guide.md
```

返回：

```json
{
  "name": "tapdb-data-analysis",
  "path": "references/sql_schema_guide.md",
  "content": "# StarRocks SQL ...",
  "size": 28910,
  "truncated": false
}
```

**何时拉**：
- SKILL.md 里写"必须阅读 references/xxx.md"或"必须读取 assets/xxx.md"——这些是硬要求，进入对应场景前先 `files` 拉
- 不要预热式全拉，按需取一份够用一份；多次 `exec` 之间内容不变可复用
- `truncated: true` 时只返回前 256KB；超大文件会截断，足够用就行

### Step 2.6 (按需): `kb` — 读 sync_skills 同步过来的项目知识库

某些 skill（典型如 tapdb-data-analysis）有"项目级 KB"概念：先 `exec sync_skills -p <pid>`，
平台从远端 TapDB 把该项目的私有文档（游戏概览/抽卡机制/商业模式等）下载到 server。
远端 agent 想读这堆文件时用本接口。

`exec sync_skills` 返回里会带 `files` + `kb_endpoint` 字段提示，按提示调即可：

```bash
# 列项目 KB 清单
python3 <SKILL_DIR>/scripts/skills.py kb tapdb-data-analysis 10005388

# 读单个文件（path 用 sync_skills 返回的 files 数组里的相对路径）
python3 <SKILL_DIR>/scripts/skills.py kb tapdb-data-analysis 10005388 'ssrpg 5/gacha_recruitment.md'
```

返回：

```json
{
  "name": "tapdb-data-analysis",
  "project_id": "10005388",
  "path": "ssrpg 5/gacha_recruitment.md",
  "content": "# 卡池 / 招募系统\n\n> 卡池是...",
  "size": 4567,
  "truncated": false
}
```

⚠️ 必须先 `exec sync_skills -p <pid>` 同步过才能读，否则 404。
⚠️ 路径名可能含空格（如 `ssrpg 5/`），命令行用单引号包起来。

### Step 3: `exec` — 让平台执行

按 step 2 的 SKILL.md 拼好命令后：

```bash
python3 <SKILL_DIR>/scripts/skills.py exec \
  --skill xds-user-auth \
  --command 'use 17' \
  --user-query '查下铃兰最近7天DAU' \
  --intent '用户选定铃兰项目以便后续查 DAU'
```

**每次 `exec` 都带上 `--user-query` 和 `--intent`**：

- `--user-query`：用户的**原话**（直接转述本轮触发本次调用的那句话即可）。
- `--intent`：你理解到的本次诉求的一句话摘要。

带上这两个字段能让平台更准确地理解你的诉求、把请求处理得更贴合（比如消歧、补默认值）。
**每次都需要带上**。

返回：

```json
{
  "output": "{\"ok\":true,\"app_id\":\"17\"}",
  "exit_code": 0,
  "elapsed_ms": 1079,
  "skill": "xds-user-auth",
  "script": "projects.py"
}
```

`use <id>` 成功后,**你**(调用方)需要把这个 `app_id` 记下来,后续 `exec` 业务 skill 时通过 `--app-id 17` 显式传进去 —— server 端不会替你记。

`output` 字段是被调用脚本写到 stdout 的内容，**通常本身又是 JSON 字符串**——
读取时记得二次 parse。

舆情分析任务通常耗时较长，优先只发起任务并拿 `task_id`，后续用 `get-task` 轮询：

```bash
python3 <SKILL_DIR>/scripts/skills.py exec \
  --skill xds-sentiment-analysis \
  --command 'analyze --kb-slug ssrpg --keywords "新角色,卡池强度" --date-range "近7天" --platforms "taptap,bilibili,tieba" --report-type "pool"'

python3 <SKILL_DIR>/scripts/skills.py exec \
  --skill xds-sentiment-analysis \
  --command 'get-task <task_id>'
```

舆情 `output` 里重点看：
- `status`：`running` / `completed` / `failed`
- `progress.stage_label`、`progress.message`、`progress.percent`：当前阶段
- `reply`：完成后的摘要
- `artifacts` / `bundle_artifact`：HTML、Markdown、DSL、CSV、ZIP 等下载产物

## 完整示例

用户问："查下铃兰最近 7 天 DAU"

```bash
# 1. 用户没指定具体项目，直接 list 看有哪些 skill
$ python3 <SKILL_DIR>/scripts/skills.py list
# → 看到 tapdb-data-analysis，requires_project=false

# 2. 拿 SKILL.md，了解工作流
$ python3 <SKILL_DIR>/scripts/skills.py get tapdb-data-analysis
# → 学到要先 list_projects --search 找项目 ID，再用 active --quota dau 查

# 3. 找项目（铃兰可能是多个项目，按 sticky=true 优先）
$ python3 <SKILL_DIR>/scripts/skills.py exec --skill tapdb-data-analysis \
    --command 'list_projects --search 铃兰'
# → output 里看到 id=10005388, sticky=true 的「铃兰之剑：为这和平的世界」

# 4. 查 DAU
$ python3 <SKILL_DIR>/scripts/skills.py exec --skill tapdb-data-analysis \
    --command 'active -p 10005388 -s 2026-04-15 -e 2026-04-21 --quota dau -g time'
# → output 是按日 DAU 数据，整理给用户
```

用户问："帮我分析铃兰项目近 7 天关于新角色和卡池强度的玩家舆情，平台看 TapTap、B站、贴吧，按卡池报告输出"

```bash
# 1. 拉取舆情 skill 说明（不需要先选项目）
$ python3 <SKILL_DIR>/scripts/skills.py get xds-sentiment-analysis
# → SKILL.md 里列出可用 slug：ssrpg=铃兰之剑、torchlight=火炬之光 等
# → "铃兰" → kb_slug=ssrpg

# 2. 发起舆情任务（无需 --app-id）
$ python3 <SKILL_DIR>/scripts/skills.py exec --skill xds-sentiment-analysis \
    --command 'analyze --kb-slug ssrpg --keywords "新角色,卡池强度" --date-range "近7天" --platforms "taptap,bilibili,tieba" --report-type "pool"'
# → output 里拿到 task_id 和 progress

# 3. 轮询任务状态
$ python3 <SKILL_DIR>/scripts/skills.py exec --skill xds-sentiment-analysis \
    --command 'get-task <task_id>'
# → completed 后基于 reply 和 artifacts 回复用户
```

## DO / DON'T

**DO**

- 第一次接触某个 skill 一定先 `get` 一次完整 SKILL.md，再 `exec`
- SKILL.md 里写"必须阅读 references/xxx.md"或"必须读取 assets/xxx.md"——按需 `files` 拉
- `exec sync_skills` 返回 `action: updated` + `files` + `kb_endpoint` 时，按提示用 `kb` 拉项目 KB
- 项目未确认时先用 `xds-user-auth list` 拿全量项目，**自己**根据用户原话挑出 `id`，再 `use <id>`；命中后把这个 `app_id` 显式传给后续 `--app-id`。`use` 只接受 id，不再接受项目名
- 舆情分析返回 `status=running` 时，不要编造结论；向用户说明当前阶段和 `task_id`，再用 `get-task` 查询
- 多个**互相独立**的查询可以**并行 `exec`**（多个 Bash 调用一起发）
- 解析 `output` 字段时记得它是 JSON 字符串（二次 `json.loads`）
- 每次 `exec` 都要带上 `--user-query`（用户原话）和 `--intent`（你理解的诉求），帮平台更准确地理解并处理请求

**DON'T**

- 不要根据 `list` 的 description 就直接 `exec`——必须先 `get` 学清楚参数
- 不要为了舆情分析调用 `tapdb-data-analysis list_projects`；舆情的项目确认统一走 `xds-user-auth`
- 不要假设平台记住了 `app_id`——每次 `exec` 都要自己传
- 不要为每次 `exec` 手工拼 `--session-id`——CLI 默认走 `~/.cache/xds-skills/session_id`（30 分钟滑动 TTL），同一任务内自动复用
- 不要为"以防万一"把所有 references/assets 全拉一遍——按 SKILL.md 提示按需取

## 错误处理

| 退出码 | 含义 | 排查 |
|--------|------|------|
| 0 | 成功 | stdout 是结果 JSON |
| 1 | HTTP 错误 / 网络错误 | stdout 是 `{"error": "...", "detail": "..."}` |
| 2 | 配置缺失 | stderr 提示缺哪个环境变量 |

常见错误：

- `HTTP 400` 提示需要 `app_id` → skill 是 `requires_project=true`，加 `--app-id`（舆情已不需要）
- `HTTP 403` → 当前 token 在该项目下没有这个 skill 的权限
- `HTTP 404` → 这个 skill 名不在公开列表里（先 `list` 看下有什么）
- 舆情返回 `kb_slug is required` → `analyze` 没传 `--kb-slug`，按用户输入推断后重试
- 舆情返回"data/sentiment-kb/project_profiles.yaml 中缺少 projects.<slug> 段" → 传入的 slug 在 KB 里不存在，让用户确认或让数分补段
- 舆情返回"请数分修订知识库 …" → KB yaml 不完整/不可运行，按提示让数分修订
- 舆情返回"知识库未挂载" → 部署侧问题，找管理员排查
- 舆情 B 站采集出现"未配置登录 Cookie"降级 → 部署侧 `XDS_SENTIMENT_BILIBILI_COOKIE` 未设，会拿到匿名样本
- `network error` → 检查 `XDS_AGENT_URL` 是否能通
