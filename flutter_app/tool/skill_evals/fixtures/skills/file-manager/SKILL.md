---
name: file-manager
description: 文件管理 — 搜索、重命名、分析目录结构、文件操作
tools: [bash, read_file, write_file]
---

## Use This Skill When
用户需要管理文件：搜索、重命名、移动、统计、分析目录

## Execution Workflow

### 常用操作

**搜索文件:**
```bash
find /root/workspace -name "*.{ext}" -type f
```

**目录分析:**
```bash
du -sh /root/workspace/*/ | sort -rh | head -20
```

**批量重命名:**
```bash
for f in /root/workspace/*.{old_ext}; do mv "$f" "${f%.old_ext}.new_ext"; done
```

**文件统计:**
```bash
find /root/workspace -type f | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -20
```

## Hard Rules
- 操作前先确认文件列表，避免误操作
- 删除操作需要用户二次确认
- 始终在 /root/workspace 内操作
