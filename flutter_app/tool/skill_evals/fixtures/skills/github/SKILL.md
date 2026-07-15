---
name: github
description: GitHub 操作 — 查看 Issue/PR、搜索代码、管理仓库
tools: [bash]
---

## Use This Skill When
用户提到 GitHub、issue、PR、pull request、仓库、repository、commit、git 操作

## Do Not Use This Skill When
用户只是在本地写代码而不涉及 GitHub 交互

## Execution Workflow

1. 确认用户需求（查看/创建/搜索）
2. 使用 bash 工具执行 curl 调用 GitHub API

### 常用 API 操作

**查看仓库信息:**
```bash
curl -s "https://api.github.com/repos/{owner}/{repo}" | jq '.full_name, .description, .stargazers_count'
```

**搜索 Issue:**
```bash
curl -s "https://api.github.com/repos/{owner}/{repo}/issues?state=open&per_page=10" | jq '.[] | {number, title, state, created_at}'
```

**查看 PR:**
```bash
curl -s "https://api.github.com/repos/{owner}/{repo}/pulls?state=open&per_page=10" | jq '.[] | {number, title, user: .user.login, created_at}'
```

**搜索代码:**
```bash
curl -s "https://api.github.com/search/code?q={query}+repo:{owner}/{repo}" | jq '.items[:5] | .[] | {path, repository: .repository.full_name}'
```

**创建 Issue:**
```bash
curl -s -X POST "https://api.github.com/repos/{owner}/{repo}/issues" \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title":"...","body":"..."}'
```

## Hard Rules
- 需要写操作（创建 issue/PR）时，提示用户配置 GITHUB_TOKEN 环境变量
- 默认使用公开 API（不需要 token），遇到 rate limit 时提示用户配置 token
- 始终用 jq 格式化输出，方便阅读

## Response Format
- 简洁展示结果，使用表格或列表
- 提供 GitHub 网页链接方便用户跳转
