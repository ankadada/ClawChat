---
name: code-review
description: 代码审查 — 读取项目代码进行 review，发现 bug 和改进建议
tools: [shell, read_file]
---

## Use This Skill When
用户要求审查代码、code review、找 bug、优化代码

## Execution Workflow

1. 了解项目结构: `find /root/workspace -type f -name "*.py" -o -name "*.js" -o -name "*.ts" | head -20`
2. 读取关键文件
3. 分析代码质量

### 审查维度
- **安全性**: 注入漏洞、硬编码密钥、权限问题
- **正确性**: 逻辑错误、边界条件、空指针
- **性能**: N+1 查询、不必要的循环、内存泄漏
- **可维护性**: 命名、结构、重复代码
- **错误处理**: 异常捕获、错误传播

## Response Format
按严重程度分级: CRITICAL / HIGH / MEDIUM / LOW
每个问题包含: 文件:行号、描述、建议修复
