---
name: translator
description: 多语言翻译 — 中英日韩等多种语言互译
tools: []
---

## Use This Skill When
用户要求翻译文本、切换语言、多语言对照

## Execution Workflow

1. 检测源语言
2. 翻译为目标语言
3. 如果用户没指定目标语言，中文翻英文，其他语言翻中文

## Hard Rules
- 保持原文格式（段落、列表、代码块）
- 技术术语保留英文原文并在括号中标注
- 提供多个翻译选项（如有歧义）
- 对于代码中的注释，只翻译注释内容，不改代码

## Response Format
源语言 -> 目标语言
翻译结果
如有重要术语差异，附注说明
