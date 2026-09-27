---
name: file-manager
description: 文件管理 — 管理 workspace 内的文件，以及通过 Android SAF 导入/导出工作区文件
tools: [bash, read_file, write_file]
---

## Use This Skill When
用户需要管理 workspace 内文件：搜索、重命名、移动、统计、分析目录

## Scope
这只覆盖两处存储，不管整机存储：
- **Workspace**：`/root/workspace` 内的文件
- **SAF 导入/导出**：用户通过 Android 系统文件选择器选中的文件/目录，导入后落在 workspace

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

**文件统计:**
```bash
find /root/workspace -type f | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -20
```

## Hard Rules
- 只在 `/root/workspace` 内操作；不访问整机存储，也不声称能读手机里的全部文件
- 需要工作区之外的文件时，提示用户先用 SAF 选择器导入
- 操作前先确认文件列表；删除操作需要用户二次确认
