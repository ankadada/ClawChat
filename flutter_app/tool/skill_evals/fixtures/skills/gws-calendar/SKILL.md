---
name: gws-calendar
description: Google Calendar API 预设（可选，非手机日历）— 需自备 GOOGLE_ACCESS_TOKEN，无应用内 OAuth
tools: [bash]
---

## Use This Skill When
用户明确要在 **Google Calendar** 里查看/创建/管理日程，并且自己提供了 access token

## Do Not Use This Skill When
用户只是问手机上的日程/今天有什么会 —— 那用 `phone_read` 的手机日历工具，不需要本技能，也不需要 GOOGLE_ACCESS_TOKEN

## Prerequisites
这是可选的 Google API 预设，调用的是 **Google Calendar API**，不是 Android 手机日历。
应用不提供内置 OAuth：用户需要在环境变量里自备 `GOOGLE_ACCESS_TOKEN`，技能才能工作。
未配置 token 时停下来提示用户，不要假装能读取手机日历。

## Execution Workflow

### 查看今日日程
```bash
curl -s "https://www.googleapis.com/calendar/v3/calendars/primary/events?timeMin=$(date -u +%Y-%m-%dT00:00:00Z)&timeMax=$(date -u +%Y-%m-%dT23:59:59Z)&singleEvents=true&orderBy=startTime" \
  -H "Authorization: Bearer $GOOGLE_ACCESS_TOKEN" | jq '.items[] | {summary, start: .start.dateTime, end: .end.dateTime, location}'
```

### 查看未来 N 天日程
```bash
curl -s "https://www.googleapis.com/calendar/v3/calendars/primary/events?timeMin=$(date -u +%Y-%m-%dT00:00:00Z)&timeMax=$(date -u -d '+7 days' +%Y-%m-%dT23:59:59Z)&singleEvents=true&orderBy=startTime" \
  -H "Authorization: Bearer $GOOGLE_ACCESS_TOKEN" | jq '.items[] | {summary, start: .start.dateTime, end: .end.dateTime}'
```

### 创建事件
```bash
curl -s -X POST "https://www.googleapis.com/calendar/v3/calendars/primary/events" \
  -H "Authorization: Bearer $GOOGLE_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "summary": "EVENT_TITLE",
    "start": {"dateTime": "2025-01-01T10:00:00+08:00"},
    "end": {"dateTime": "2025-01-01T11:00:00+08:00"},
    "description": "EVENT_DESCRIPTION"
  }'
```

### 搜索事件
```bash
curl -s "https://www.googleapis.com/calendar/v3/calendars/primary/events?q=SEARCH_TERM&singleEvents=true&orderBy=startTime" \
  -H "Authorization: Bearer $GOOGLE_ACCESS_TOKEN" | jq '.items[:10] | .[] | {summary, start: .start.dateTime}'
```

## Hard Rules
- 创建/修改事件前确认时区（默认使用用户所在时区）
- 展示日程时使用清晰的时间格式
- 如果 token 过期(401)，提示用户刷新 GOOGLE_ACCESS_TOKEN
