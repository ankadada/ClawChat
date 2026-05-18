---
name: gws-drive
description: Google Drive — 查看文件、搜索文件、管理云端硬盘
tools: [bash]
---

## Use This Skill When
用户提到 Google Drive、云端硬盘、网盘文件、Google Docs/Sheets

## Prerequisites
需要在环境变量中配置 `GOOGLE_ACCESS_TOKEN`（需要 Drive API scope）。

## Execution Workflow

### 列出最近文件
```bash
curl -s "https://www.googleapis.com/drive/v3/files?pageSize=20&orderBy=modifiedTime desc&fields=files(id,name,mimeType,modifiedTime,size)" \
  -H "Authorization: Bearer $GOOGLE_ACCESS_TOKEN" | jq '.files[] | {name, type: .mimeType, modified: .modifiedTime, size}'
```

### 搜索文件
```bash
curl -s "https://www.googleapis.com/drive/v3/files?q=name+contains+'SEARCH_TERM'&fields=files(id,name,mimeType,modifiedTime)" \
  -H "Authorization: Bearer $GOOGLE_ACCESS_TOKEN" | jq '.files[]'
```

### 按类型搜索
```bash
# Google Docs
curl -s "https://www.googleapis.com/drive/v3/files?q=mimeType='application/vnd.google-apps.document'&pageSize=10&fields=files(id,name,modifiedTime)" \
  -H "Authorization: Bearer $GOOGLE_ACCESS_TOKEN" | jq '.files[]'

# Google Sheets
curl -s "https://www.googleapis.com/drive/v3/files?q=mimeType='application/vnd.google-apps.spreadsheet'&pageSize=10&fields=files(id,name,modifiedTime)" \
  -H "Authorization: Bearer $GOOGLE_ACCESS_TOKEN" | jq '.files[]'
```

### 读取 Google Doc 内容
```bash
curl -s "https://www.googleapis.com/drive/v3/files/FILE_ID/export?mimeType=text/plain" \
  -H "Authorization: Bearer $GOOGLE_ACCESS_TOKEN"
```

### 下载文件
```bash
curl -s "https://www.googleapis.com/drive/v3/files/FILE_ID?alt=media" \
  -H "Authorization: Bearer $GOOGLE_ACCESS_TOKEN" -o "/root/workspace/downloads/FILENAME"
```

### 查看文件详情
```bash
curl -s "https://www.googleapis.com/drive/v3/files/FILE_ID?fields=id,name,mimeType,size,modifiedTime,owners,shared,webViewLink" \
  -H "Authorization: Bearer $GOOGLE_ACCESS_TOKEN" | jq '.'
```

## Hard Rules
- 删除文件操作需要二次确认
- 展示文件大小时使用人类可读格式
- 提供 webViewLink 方便用户在浏览器中打开
- token 过期时提示刷新

## Response Format
文件列表用表格展示：文件名、类型、修改时间、大小
