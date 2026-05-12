---
name: gws-gmail
description: Gmail — 查看邮件、搜索邮件、发送邮件
tools: [shell]
---

## Use This Skill When
用户提到邮件、收件箱、Gmail、发邮件、查邮件

## Prerequisites
需要在环境变量中配置 `GOOGLE_ACCESS_TOKEN`（需要 Gmail API scope）。

## Execution Workflow

### 查看最近邮件
```bash
curl -s "https://www.googleapis.com/gmail/v1/users/me/messages?maxResults=10" \
  -H "Authorization: Bearer $GOOGLE_ACCESS_TOKEN" | jq '.messages[].id' | while read id; do
  curl -s "https://www.googleapis.com/gmail/v1/users/me/messages/$(echo $id | tr -d '"')?format=metadata&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=Date" \
    -H "Authorization: Bearer $GOOGLE_ACCESS_TOKEN" | jq '{id: .id, snippet: .snippet, headers: [.payload.headers[] | {(.name): .value}] | add}'
done
```

### 搜索邮件
```bash
curl -s "https://www.googleapis.com/gmail/v1/users/me/messages?q=SEARCH_QUERY&maxResults=10" \
  -H "Authorization: Bearer $GOOGLE_ACCESS_TOKEN" | jq '.messages[].id'
```

### 读取邮件内容
```bash
curl -s "https://www.googleapis.com/gmail/v1/users/me/messages/MESSAGE_ID?format=full" \
  -H "Authorization: Bearer $GOOGLE_ACCESS_TOKEN" | jq '{subject: (.payload.headers[] | select(.name=="Subject") | .value), from: (.payload.headers[] | select(.name=="From") | .value), snippet: .snippet}'
```

### 发送邮件
```bash
# 构造 RFC 2822 格式邮件并 base64url 编码
EMAIL=$(printf "To: RECIPIENT@example.com\nSubject: SUBJECT\nContent-Type: text/plain; charset=utf-8\n\nBODY_TEXT" | base64 -w 0 | tr '+/' '-_' | tr -d '=')
curl -s -X POST "https://www.googleapis.com/gmail/v1/users/me/messages/send" \
  -H "Authorization: Bearer $GOOGLE_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"raw\": \"$EMAIL\"}"
```

## Hard Rules
- 发送邮件前必须确认收件人和内容
- 不要展示邮件中的敏感信息（密码、token 等）
- 搜索时使用 Gmail 搜索语法（from:, to:, subject:, has:attachment 等）
- token 过期时提示刷新

## Response Format
邮件列表用表格展示：发件人、主题、时间、摘要
