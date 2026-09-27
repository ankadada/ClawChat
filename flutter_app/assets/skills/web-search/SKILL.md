---
name: web-search
description: 网页搜索与信息摘要 — 调用内置 web_search / web_fetch 工具，不用命令行抓网页
tools: [web_search, web_fetch]
---

## Use This Skill When
用户需要搜索网上信息、查找最新资讯、了解某个话题

## 执行方式

1. 用内置 `web_search` 工具检索关键词，读取结构化结果（标题、URL、摘要）
2. 需要正文时用内置 `web_fetch` 工具读取具体 URL
3. 汇总关键信息并注明来源

## Hard Rules
- 只走内置 `web_search` / `web_fetch` 工具；不要用 shell 命令直接抓网页
- 搜索结果要总结成摘要，不要直接输出 HTML
- 标注信息来源 URL
