---
name: system-info
description: 系统信息 — 查看进程、磁盘、网络、环境状态
tools: [bash]
---

## Use This Skill When
用户询问系统状态、磁盘空间、运行进程、网络情况

## Execution Workflow

**系统概览:**
```bash
echo "=== Disk ===" && df -h / && echo "=== Memory ===" && free -h && echo "=== Uptime ===" && uptime
```

**进程列表:**
```bash
ps aux --sort=-%mem | head -15
```

**网络状态:**
```bash
ip addr show 2>/dev/null || ifconfig 2>/dev/null; echo "---"; cat /etc/resolv.conf
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
