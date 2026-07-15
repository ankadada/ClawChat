---
name: web-search
description: 网页搜索与信息摘要 — 使用搜索引擎查找信息
tools: [bash, web_fetch]
---

## Use This Skill When
用户需要搜索网上信息、查找最新资讯、了解某个话题

## Execution Workflow

1. 使用 web_fetch 工具访问搜索引擎或直接访问目标网页
2. 提取关键信息并总结

### 搜索方式

**使用 DuckDuckGo (无需 API key):**
```bash
curl -s "https://html.duckduckgo.com/html/?q=$(echo '{query}' | sed 's/ /+/g')" | grep -oP 'href="https?://[^"]*"' | head -10
```

**直接访问网页:**
使用 web_fetch 工具获取网页内容并提取信息。

## Hard Rules
- 优先使用 web_fetch 工具（有 SSRF 防护）
- 搜索结果需要总结摘要，不要直接输出 HTML
- 注明信息来源 URL
