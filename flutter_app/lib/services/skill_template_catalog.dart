import '../models/skill_template.dart';

/// App-owned local workflow templates.
///
/// Every template is compiled into the app: there is no URL, no installer
/// command, and no remote fetch. Installing one writes a local `SKILL.md` under
/// the workspace skills directory and leaves it disabled until the existing
/// skill consent enables it.
abstract final class SkillTemplateCatalog {
  static const dailyWorkSummary = SkillTemplate(
    id: 'template.daily-work-summary',
    stableSkillId: 'daily-work-summary',
    name: '每日工作总结',
    summary: '汇总工作区里今天的改动，生成一份本地总结草稿。',
    version: 1,
    capabilities: [
      SkillTemplateCapability(
        id: 'workspace.read',
        label: '读取工作区文件',
        rationale: '读取今天的改动与已有笔记。',
      ),
      SkillTemplateCapability(
        id: 'workspace.write',
        label: '写入工作区文件',
        rationale: '把总结草稿写入工作区，等待你确认。',
      ),
      SkillTemplateCapability(
        id: 'memory.read',
        label: '读取本地记忆',
        rationale: '沿用你保存过的总结格式偏好。',
      ),
    ],
    networkAccess: false,
    sensitiveData: [],
    body: '''
# 每日工作总结

把工作区里今天变更的文件整理成一份本地总结草稿。

## 步骤
1. 列出工作区中今天修改过的文件，先跳过缓存与临时文件。
2. 读取与改动相关的笔记或说明，提取要点。
3. 按「完成了什么 / 卡在哪里 / 明天先做什么」三段生成总结。
4. 把总结写入 `workspace/summaries/daily-YYYY-MM-DD.md`，写完告知路径。

## 边界
- 只读写工作区文件，不访问网络。
- 不发送、不分享、不调用电话或短信。
- 写入前如果目标文件已存在，先询问是否覆盖。
''',
  );

  static const calendarBriefing = SkillTemplate(
    id: 'template.calendar-briefing',
    stableSkillId: 'calendar-briefing',
    name: '日程提醒草稿',
    summary: '把近期日历事件整理成当天行程草稿，需要时先在对话里确认。',
    version: 1,
    capabilities: [
      SkillTemplateCapability(
        id: 'phone.calendar.read',
        label: '读取日历',
        rationale: '读取近期事件标题与时间，用于生成行程草稿。',
      ),
      SkillTemplateCapability(
        id: 'workspace.write',
        label: '写入工作区文件',
        rationale: '把行程草稿写入工作区供你查看。',
      ),
    ],
    networkAccess: false,
    sensitiveData: ['日历事件标题、时间与地点'],
    body: '''
# 日程提醒草稿

把近期日历事件整理成一份当天行程草稿。

## 步骤
1. 调用 `phone_read` 的 `listCalendarEvents` 读取今天到未来 7 天的事件。
2. 按时间顺序排列，标注冲突时段与需要提前准备的事项。
3. 把草稿写入 `workspace/summaries/briefing-YYYY-MM-DD.md`。
4. 询问是否需要把其中一项加入提醒；加提醒前必须再确认。

## 边界
- 日历只读；写入事件只能用 `phone_act.insertCalendarEvent` 并在对话中确认。
- 不发送短信、不拨打电话、不访问网络。
- 日历内容属于手机隐私数据，不要在未确认时复制到工作区以外的位置。
''',
  );

  static const entries = <SkillTemplate>[
    dailyWorkSummary,
    calendarBriefing,
  ];

  static SkillTemplate? byId(String id) {
    for (final template in entries) {
      if (template.id == id) return template;
    }
    return null;
  }

  static SkillTemplate? byStableSkillId(String stableSkillId) {
    for (final template in entries) {
      if (template.stableSkillId == stableSkillId) return template;
    }
    return null;
  }
}
