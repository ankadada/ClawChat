---
name: gws-calendar
description: Google Calendar — 查看日程、创建事件、管理日历
tools: [shell]
---

## Use This Skill When
用户提到日历、日程、会议、行程安排、Google Calendar

## Prerequisites
需要在环境变量中配置 `GOOGLE_ACCESS_TOKEN`。

获取方式: 使用 OAuth2 授权后获取 access token，或使用 Google Cloud Service Account。

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

## Response Format
以表格或时间线格式展示日程，标注时间和地点
