---
name: system-info
description: 机器健康 — 查看本机 Alpine/proot 运行环境的磁盘、内存、进程、包与 Python 状态
tools: [bash]
---

## Use This Skill When
用户询问这台机器/运行环境的健康状态：磁盘空间、内存、运行进程、已装包

## Scope
这里说的是**这台机器**（ClawChat 在 Android 上运行的 Alpine/proot 环境）的健康，
不是手机系统状态。手机信号、电池、机型等请用 `phone_read` / 相应手机工具，
不要用 `uname` 冒充手机状态。

## Execution Workflow

**机器概览:**
```bash
echo "=== Disk ===" && df -h / && echo "=== Memory ===" && free -h && echo "=== Uptime ===" && uptime
```

**进程列表:**
```bash
ps aux --sort=-%mem | head -15
```

**已安装包:**
```bash
apk list --installed 2>/dev/null | wc -l && echo "packages installed"
```

**Python 环境:**
```bash
python3 --version && pip3 list 2>/dev/null | head -20
```

## Hard Rules
- 信息以人类可读格式展示
- 不执行修改系统状态的操作（除非用户明确要求）
- 不把 proot 里的 `uname` 结果当成手机状态汇报
