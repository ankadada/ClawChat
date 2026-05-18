# ClawChat 技术设计文档

> **版本**: 1.0  
> **日期**: 2026-05-11  
> **目标**: 说明 ClawChat 当前架构，并保留从 OpenClaw 迁移而来的历史设计记录
> **一句话**: 一个 APK = 原生聊天 UI + Dart Agent Loop + 嵌入式 Alpine Linux 环境

---

## Current Architecture

ClawChat 当前包名为 `com.anka.clawbot`。应用由 Flutter/Dart UI、`ChangeNotifier` 状态管理、Dart 侧 `AgentService` 工具循环、Kotlin `NativeBridge`/`ProcessManager` 原生桥接，以及通过 proot 运行的 Alpine Linux rootfs 组成。

当前执行路径是直接工具调用：用户消息进入 `ChatProvider`，由 `AgentService` 调用 `LlmService`，需要工具时通过 `ToolRegistry` 直接执行 Bash、文件读写、网页抓取等工具；Shell/文件操作通过 Kotlin MethodChannel 进入 proot Alpine 环境。当前架构不再使用中间服务进程、OpenClaw 服务进程或 Ubuntu rootfs。

---

## 目录

0. [Current Architecture](#current-architecture)
1. [架构总览](#1-架构总览)
2. [Phase 1: 项目瘦身 — 砍 OpenClaw，换 Alpine](#2-phase-1-项目瘦身--砍-openclaw换-alpine1-天)
3. [Phase 2: Dart Agent Loop + 工具系统](#3-phase-2-dart-agent-loop--工具系统2-天)
4. [Phase 3: 数据模型 + 会话管理](#4-phase-3-数据模型--会话管理1-天)
5. [Phase 4: 聊天界面](#5-phase-4-聊天界面3-天)
6. [Phase 5: 导航 + 设置 + 打磨](#6-phase-5-导航--设置--打磨2-天)
7. [API 数据结构详解](#7-api-数据结构详解)
8. [文件清单](#8-文件清单)
9. [测试检查清单](#9-测试检查清单)

---

## Migration History (Archive)

> 以下编号章节保留为从 OpenClaw/Ubuntu/Node/Gateway 迁移到当前 ClawChat/Alpine/Dart 直连工具架构的历史设计记录。内容中的 before/after 代码块和删除清单属于迁移档案；当前实现以本文顶部的 **Current Architecture** 为准。

## 1. 架构总览

### 1.1 系统架构图 (ASCII)

```
┌──────────────────────────────────────────────────────────────────┐
│                        ClawChat APK                              │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                   Flutter UI Layer                       │    │
│  │                                                         │    │
│  │  ┌──────────┐  ┌──────────────┐  ┌─────────────────┐   │    │
│  │  │ ChatScreen│  │SessionsScreen│  │  SettingsScreen  │   │    │
│  │  └────┬─────┘  └──────┬───────┘  └────────┬────────┘   │    │
│  │       │               │                    │            │    │
│  │  ┌────┴───────────────┴────────────────────┴────────┐   │    │
│  │  │              ChatProvider (State)                  │   │    │
│  │  │         (会话列表、当前消息、Agent 状态)            │   │    │
│  │  └────────────────────┬──────────────────────────────┘   │    │
│  └───────────────────────┼──────────────────────────────────┘    │
│                          │                                       │
│  ┌───────────────────────┼──────────────────────────────────┐    │
│  │                 Service Layer                             │    │
│  │                       │                                   │    │
│  │  ┌────────────────────┴─────────────────────┐            │    │
│  │  │           AgentService                    │            │    │
│  │  │  ┌─────────────────────────────────────┐  │            │    │
│  │  │  │          Agent Loop                  │  │            │    │
│  │  │  │  while(true) {                       │  │            │    │
│  │  │  │    response = LLM.chat(messages)     │  │            │    │
│  │  │  │    if stop_reason != tool_use: break │  │            │    │
│  │  │  │    results = execute_tools(response) │  │            │    │
│  │  │  │    messages.append(results)          │  │            │    │
│  │  │  │  }                                   │  │            │    │
│  │  │  └─────────────────────────────────────┘  │            │    │
│  │  └──────┬──────────────┬─────────────────────┘            │    │
│  │         │              │                                   │    │
│  │  ┌──────┴──────┐ ┌────┴──────────────────────────┐       │    │
│  │  │ LLMService  │ │       ToolRegistry             │       │    │
│  │  │             │ │                                │       │    │
│  │  │ Anthropic   │ │ ┌────────┐ ┌────────────────┐  │       │    │
│  │  │ OpenAI      │ │ │BashTool│ │ ReadFileTool   │  │       │    │
│  │  │ SSE Stream  │ │ ├────────┤ ├────────────────┤  │       │    │
│  │  │ 自定义 URL  │ │ │WriteTool│ │ WebFetchTool  │  │       │    │
│  │  └──────┬──────┘ │ └───┬────┘ └────────────────┘  │       │    │
│  │         │        └─────┼──────────────────────────┘       │    │
│  │         │              │                                   │    │
│  └─────────┼──────────────┼───────────────────────────────────┘    │
│            │              │                                       │
│  ┌─────────┴──────────────┴───────────────────────────────────┐  │
│  │                   NativeBridge (MethodChannel)              │  │
│  │         Flutter Dart  <──────────>  Android Kotlin          │  │
│  └─────────┬──────────────────────────────────────────────────┘  │
│            │                                                      │
│  ┌─────────┴──────────────────────────────────────────────────┐  │
│  │                  Android Native Layer                       │  │
│  │                                                             │  │
│  │  ┌──────────────────┐  ┌──────────────────────────────┐    │  │
│  │  │ BootstrapManager │  │       ProcessManager          │    │  │
│  │  │                  │  │                                │    │  │
│  │  │ - 下载 Alpine    │  │ - buildShellCommand()         │    │  │
│  │  │ - 解压 rootfs    │  │ - runInProotSync()            │    │  │
│  │  │ - 配置 apk 源    │  │ - startProotProcess()         │    │  │
│  │  └──────────────────┘  └───────────────┬──────────────┘    │  │
│  │                                         │                   │  │
│  │  ┌──────────────────────────────────────┴─────────────┐    │  │
│  │  │                  proot (libproot.so)                 │    │  │
│  │  │                                                     │    │  │
│  │  │  ┌───────────────────────────────────────────────┐  │    │  │
│  │  │  │        Alpine Linux minirootfs (~50MB)         │  │    │  │
│  │  │  │                                               │  │    │  │
│  │  │  │  /bin/sh (busybox)                            │  │    │  │
│  │  │  │  /usr/bin/python3, pip, curl, git, jq        │  │    │  │
│  │  │  │  /root/workspace/  ← Agent 工作目录           │  │    │  │
│  │  │  └───────────────────────────────────────────────┘  │    │  │
│  │  └─────────────────────────────────────────────────────┘    │  │
│  └─────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

### 1.2 数据流向图

```
用户输入消息
      │
      ▼
ChatProvider.sendMessage()
      │
      ▼
AgentService.runAgentLoop()
      │
      ├──────────────────────────────────────────┐
      ▼                                          │
LLMService.chat(messages, tools)                 │
      │                                          │
      ▼                                          │
SSE Stream ──► 实时更新 UI                       │
      │                                          │
      ▼                                          │
stop_reason == "tool_use" ?                      │
      │                                          │
   ┌──┴──┐                                       │
   │ Yes │                                       │
   └──┬──┘                                       │
      ▼                                          │
ToolRegistry.executeTool()                       │
      │                                          │
      ├─ BashTool ──► NativeBridge.runInProot()  │
      ├─ ReadFileTool ──► 读取 rootfs 文件       │
      ├─ WriteFileTool ──► 写入 rootfs 文件      │
      └─ WebFetchTool ──► HTTP 请求              │
      │                                          │
      ▼                                          │
tool_result 追加到 messages                      │
      │                                          │
      └──────────────────────────────────────────┘
      │
   ┌──┴──┐
   │ No  │ (stop_reason == "end_turn")
   └──┬──┘
      ▼
最终回复展示在 ChatScreen
```

### 1.3 目录结构 (改造后)

```
flutter_app/
├── android/
│   └── app/src/main/kotlin/com/anka/clawbot/
│       ├── MainActivity.kt          [修改] 精简方法, 改包名
│       ├── BootstrapManager.kt      [修改] ubuntu→alpine, 去 APT/Node
│       ├── ProcessManager.kt        [修改] 路径 ubuntu→alpine
│       ├── ArchUtils.kt             [保留]
│       ├── SetupService.kt          [保留]
│       └── TerminalSessionService.kt[保留]
│       # 删除: GatewayService.kt, NodeForegroundService.kt,
│       #       SshForegroundService.kt, ScreenCaptureService.kt
│
├── lib/
│   ├── main.dart                    [保留]
│   ├── app.dart                     [修改] 路由改造, 品牌改名
│   ├── constants.dart               [修改] URL→Alpine, 去 Node
│   │
│   ├── models/
│   │   ├── chat_models.dart         [新建] ChatSession, ChatMessage, ContentBlock
│   │   └── setup_state.dart         [修改] 简化步骤
│   │   # 删除: ai_provider.dart, gateway_state.dart,
│   │   #       node_frame.dart, node_state.dart, optional_package.dart
│   │
│   ├── providers/
│   │   └── chat_provider.dart       [新建] 核心状态管理
│   │   # 删除: gateway_provider.dart, node_provider.dart, setup_provider.dart
│   │
│   ├── services/
│   │   ├── native_bridge.dart       [修改] 精简方法
│   │   ├── bootstrap_service.dart   [修改] Alpine 流程
│   │   ├── preferences_service.dart [修改] 增加 API key 存储
│   │   ├── terminal_service.dart    [修改] 路径调整
│   │   ├── llm_service.dart         [新建] LLM API 客户端
│   │   ├── agent_service.dart       [新建] Agent Loop 核心
│   │   ├── session_storage.dart     [新建] 会话持久化
│   │   └── tools/
│   │       ├── tool_registry.dart   [新建] 工具注册/路由
│   │       ├── bash_tool.dart       [新建] Shell 执行
│   │       ├── read_file_tool.dart  [新建] 文件读取
│   │       ├── write_file_tool.dart [新建] 文件写入
│   │       └── web_fetch_tool.dart  [新建] 网页抓取
│   │   # 删除: gateway_service.dart, node_service.dart, node_ws_service.dart,
│   │   #       node_identity_service.dart, package_service.dart,
│   │   #       provider_config_service.dart, update_service.dart,
│   │   #       screenshot_service.dart, ssh_service.dart,
│   │   #       capabilities/ (整个目录)
│   │
│   ├── screens/
│   │   ├── chat_screen.dart         [新建] 主聊天界面
│   │   ├── chat_sessions_screen.dart[新建] 会话列表
│   │   ├── dashboard_screen.dart    [修改] 改为主页入口
│   │   ├── settings_screen.dart     [修改] API key 配置
│   │   ├── onboarding_screen.dart   [修改] 原生表单
│   │   ├── splash_screen.dart       [保留]
│   │   ├── setup_wizard_screen.dart [修改] 简化步骤
│   │   └── terminal_screen.dart     [保留] 保留终端访问
│   │   # 删除: web_dashboard_screen.dart, node_screen.dart,
│   │   #       configure_screen.dart, providers_screen.dart,
│   │   #       provider_detail_screen.dart, packages_screen.dart,
│   │   #       package_install_screen.dart, logs_screen.dart,
│   │   #       ssh_screen.dart
│   │
│   └── widgets/
│       ├── tool_call_card.dart      [新建] 工具调用卡片
│       ├── streaming_text.dart      [新建] 流式 Markdown
│       ├── code_block.dart          [新建] 代码高亮
│       ├── agent_status_bar.dart    [新建] Agent 状态指示
│       └── progress_step.dart       [保留]
│       # 删除: gateway_controls.dart, node_controls.dart,
│       #       status_card.dart, terminal_toolbar.dart
│
└── pubspec.yaml                     [修改] 依赖调整
```

---

## 2. Phase 1: 项目瘦身 — 砍 OpenClaw，换 Alpine (1 天)

### 2.1 Alpine minirootfs 下载 URL

Alpine Linux 使用 `minirootfs` 发行版，体积约 2.5-3MB 压缩 / 8-10MB 解压，远小于 Ubuntu base (~50MB 压缩 / ~200MB 解压)。

三种架构的下载地址:

```
# aarch64 (ARM64, 大多数现代 Android 手机)
https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.3-aarch64.tar.gz

# armv7 (32-bit ARM, 旧设备)
https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/armv7/alpine-minirootfs-3.21.3-armv7.tar.gz

# x86_64 (模拟器, Chromebook)
https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/alpine-minirootfs-3.21.3-x86_64.tar.gz
```

### 2.2 修改 `constants.dart`

**文件**: `flutter_app/lib/constants.dart`

**修改前** (关键部分):
```dart
class AppConstants {
  static const String appName = 'OpenClaw';
  static const String version = '1.8.7';
  static const String packageName = 'com.nxg.openclawproot';

  // ... 省略其他 ...

  static const String ubuntuRootfsUrl =
      'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-';
  static const String rootfsArm64 = '${ubuntuRootfsUrl}arm64.tar.gz';
  static const String rootfsArmhf = '${ubuntuRootfsUrl}armhf.tar.gz';
  static const String rootfsAmd64 = '${ubuntuRootfsUrl}amd64.tar.gz';

  static const String nodeVersion = '22.14.0';
  static const String nodeBaseUrl =
      'https://nodejs.org/dist/v$nodeVersion/node-v$nodeVersion-linux-';

  static String getNodeTarballUrl(String arch) { ... }

  static const String gatewayHost = '127.0.0.1';
  static const int gatewayPort = 18789;
  static const String gatewayUrl = 'http://$gatewayHost:$gatewayPort';

  static const String channelName = 'com.nxg.openclawproot/native';
  static const String eventChannelName = 'com.nxg.openclawproot/gateway_logs';
}
```

**修改后**:
```dart
class AppConstants {
  static const String appName = 'ClawChat';
  static const String version = '2.0.0';
  static const String packageName = 'com.nxg.clawchat';

  /// ANSI 转义序列匹配
  static final ansiEscape = RegExp(r'\x1b\[[0-9;]*[a-zA-Z]');

  static const String authorName = 'ClawChat Team';
  static const String githubUrl = 'https://github.com/user/clawchat';
  static const String license = 'MIT';

  // ── Alpine minirootfs URL ──────────────────────────────────────
  static const String alpineVersion = '3.21.3';
  static const String alpineBaseUrl =
      'https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/';

  static const String rootfsArm64 =
      '${alpineBaseUrl}aarch64/alpine-minirootfs-$alpineVersion-aarch64.tar.gz';
  static const String rootfsArmhf =
      '${alpineBaseUrl}armv7/alpine-minirootfs-$alpineVersion-armv7.tar.gz';
  static const String rootfsAmd64 =
      '${alpineBaseUrl}x86_64/alpine-minirootfs-$alpineVersion-x86_64.tar.gz';

  // ── MethodChannel ──────────────────────────────────────────────
  static const String channelName = 'com.nxg.clawchat/native';
  // 删除 eventChannelName (不再需要 gateway log stream)

  // ── Agent 默认配置 ─────────────────────────────────────────────
  static const String defaultModel = 'claude-sonnet-4-20250514';
  static const int defaultMaxTokens = 8096;
  static const String defaultSystemPrompt =
      'You are a helpful AI assistant with access to tools. '
      'You run inside an Alpine Linux environment on an Android device. '
      'You can execute shell commands, read/write files, and fetch web pages.';

  static String getRootfsUrl(String arch) {
    switch (arch) {
      case 'aarch64':
        return rootfsArm64;
      case 'arm':
        return rootfsArmhf;
      case 'x86_64':
        return rootfsAmd64;
      default:
        return rootfsArm64;
    }
  }
}
```

**删除的内容**: Node.js URL、Gateway URL/Port、Node 相关常量、WebSocket 重连参数。

### 2.3 修改 `BootstrapManager.kt`

**文件**: `flutter_app/android/app/src/main/kotlin/com/nxg/clawchat/BootstrapManager.kt`

**关键改动**: 路径 `ubuntu` -> `alpine`, 移除 APT/dpkg 配置, 移除 Node.js/OpenClaw 安装。

**修改前** (关键变量):
```kotlin
private val rootfsDir get() = "$filesDir/rootfs/ubuntu"
```

**修改后**:
```kotlin
private val rootfsDir get() = "$filesDir/rootfs/alpine"
```

**修改前** (`isBootstrapComplete()`):
```kotlin
fun isBootstrapComplete(): Boolean {
    val rootfs = File(rootfsDir)
    val binBash = File("$rootfsDir/bin/bash")
    val bypass = File("$rootfsDir/root/.openclaw/bionic-bypass.js")
    val node = File("$rootfsDir/usr/local/bin/node")
    val openclaw = File("$rootfsDir/usr/local/lib/node_modules/openclaw/package.json")
    return rootfs.exists() && binBash.exists() && bypass.exists()
        && node.exists() && openclaw.exists()
}
```

**修改后**:
```kotlin
fun isBootstrapComplete(): Boolean {
    val rootfs = File(rootfsDir)
    val binSh = File("$rootfsDir/bin/sh")        // Alpine 用 busybox sh
    val binBash = File("$rootfsDir/bin/bash")     // 我们安装的 bash
    val apkDb = File("$rootfsDir/lib/apk/db/installed")
    return rootfs.exists() && (binSh.exists() || binBash.exists())
        && apkDb.exists()
}
```

**修改前** (`getBootstrapStatus()`):
```kotlin
fun getBootstrapStatus(): Map<String, Any> {
    val rootfsExists = File(rootfsDir).exists()
    val binBashExists = File("$rootfsDir/bin/bash").exists()
    val nodeExists = File("$rootfsDir/usr/local/bin/node").exists()
    val openclawExists = File("$rootfsDir/usr/local/lib/node_modules/openclaw/package.json").exists()
    val bypassExists = File("$rootfsDir/root/.openclaw/bionic-bypass.js").exists()
    return mapOf(
        "rootfsExists" to rootfsExists,
        "binBashExists" to binBashExists,
        "nodeInstalled" to nodeExists,
        "openclawInstalled" to openclawExists,
        "bypassInstalled" to bypassExists,
        "rootfsPath" to rootfsDir,
        "complete" to (rootfsExists && binBashExists && bypassExists
            && nodeExists && openclawExists)
    )
}
```

**修改后**:
```kotlin
fun getBootstrapStatus(): Map<String, Any> {
    val rootfsExists = File(rootfsDir).exists()
    val binShExists = File("$rootfsDir/bin/sh").exists()
    val binBashExists = File("$rootfsDir/bin/bash").exists()
    val pythonExists = File("$rootfsDir/usr/bin/python3").exists()
    val curlExists = File("$rootfsDir/usr/bin/curl").exists()
    return mapOf(
        "rootfsExists" to rootfsExists,
        "binShExists" to binShExists,
        "binBashExists" to binBashExists,
        "pythonInstalled" to pythonExists,
        "curlInstalled" to curlExists,
        "rootfsPath" to rootfsDir,
        "complete" to (rootfsExists && (binShExists || binBashExists))
    )
}
```

**修改前** (`configureRootfs()` 中的 APT/dpkg 配置):
```kotlin
// 1. Disable apt sandboxing
val aptConfDir = File("$rootfsDir/etc/apt/apt.conf.d")
aptConfDir.mkdirs()
File(aptConfDir, "01-openclaw-proot").writeText(
    "APT::Sandbox::User \"root\";\n" + ...
)

// 2. Configure dpkg for proot compatibility
val dpkgConfDir = File("$rootfsDir/etc/dpkg/dpkg.cfg.d")
dpkgConfDir.mkdirs()
File(dpkgConfDir, "01-openclaw-proot").writeText( ... )
```

**修改后** (替换为 Alpine apk 配置):
```kotlin
private fun configureRootfs() {
    // 1. 配置 Alpine apk 镜像源
    val apkReposDir = File("$rootfsDir/etc/apk")
    apkReposDir.mkdirs()
    File(apkReposDir, "repositories").writeText(
        "https://dl-cdn.alpinelinux.org/alpine/v3.21/main\n" +
        "https://dl-cdn.alpinelinux.org/alpine/v3.21/community\n"
    )

    // 2. 确保必要目录存在
    listOf(
        "$rootfsDir/etc/ssl/certs",
        "$rootfsDir/tmp",
        "$rootfsDir/var/tmp",
        "$rootfsDir/root",
        "$rootfsDir/root/workspace",     // Agent 工作目录
        "$rootfsDir/root/.clawchat",     // ClawChat 配置目录
        "$rootfsDir/run",
        "$rootfsDir/dev/shm",
    ).forEach { File(it).mkdirs() }

    // 3. /etc/hosts
    val hosts = File("$rootfsDir/etc/hosts")
    if (!hosts.exists() || !hosts.readText().contains("localhost")) {
        hosts.writeText(
            "127.0.0.1   localhost.localdomain localhost\n" +
            "::1         localhost.localdomain localhost\n"
        )
    }

    // 4. /tmp 权限
    val tmpDir = File("$rootfsDir/tmp")
    tmpDir.mkdirs()
    tmpDir.setReadable(true, false)
    tmpDir.setWritable(true, false)
    tmpDir.setExecutable(true, false)

    // 5. 修复 bin 目录权限
    fixBinPermissions()

    // 6. 注册 Android 用户/组
    registerAndroidUsers()
}
```

**完全删除的方法**:
- `extractDebPackages()` — Ubuntu dpkg 专用
- `extractSingleDeb()` — Ubuntu dpkg 专用
- `extractNodeTarball()` — Node.js 安装
- `createBinWrappers()` — Node.js npm 专用
- `installBionicBypass()` — Node.js/OpenClaw 专用
- `checkNodeInProot()` — Node.js 检查
- `checkOpenClawInProot()` — OpenClaw 检查

### 2.4 修改 `ProcessManager.kt`

**文件**: `flutter_app/android/app/src/main/kotlin/com/nxg/clawchat/ProcessManager.kt`

唯一改动: 路径。

**修改前**:
```kotlin
private val rootfsDir get() = "$filesDir/rootfs/ubuntu"
```

**修改后**:
```kotlin
private val rootfsDir get() = "$filesDir/rootfs/alpine"
```

同时删除 `buildGatewayCommand()` 方法中的 `NODE_OPTIONS` 环境变量行:
```kotlin
// 删除这行:
"NODE_OPTIONS=$nodeOptions",
```

将 `buildGatewayCommand()` 重命名为 `buildShellCommand()`, 用于通用 shell 执行。删除 Gateway 相关的 `NODE_EXTRA_CA_CERTS`、`CHOKIDAR_USEPOLLING`、`UV_USE_IO_URING` 等环境变量。

### 2.5 修改 `bootstrap_service.dart`

**文件**: `flutter_app/lib/services/bootstrap_service.dart`

**修改前** (主要流程):
```
Step 1: 下载 Ubuntu rootfs (~50MB)
Step 2: 解压 rootfs
Step 3: apt-get update + install ca-certificates git python3 make g++
Step 4: 下载 Node.js 二进制包
Step 5: 解压 Node.js
Step 6: npm install -g openclaw
Step 7: 验证 openclaw
```

**修改后** (精简流程):
```dart
import 'dart:io';
import 'package:dio/dio.dart';
import '../constants.dart';
import '../models/setup_state.dart';
import 'native_bridge.dart';

class BootstrapService {
  final Dio _dio = Dio();

  void _updateSetupNotification(String text, {int progress = -1}) {
    try {
      NativeBridge.updateSetupNotification(text, progress: progress);
    } catch (_) {}
  }

  void _stopSetupService() {
    try {
      NativeBridge.stopSetupService();
    } catch (_) {}
  }

  Future<SetupState> checkStatus() async {
    try {
      final complete = await NativeBridge.isBootstrapComplete();
      if (complete) {
        return const SetupState(
          step: SetupStep.complete,
          progress: 1.0,
          message: '环境就绪',
        );
      }
      return const SetupState(
        step: SetupStep.checkingStatus,
        progress: 0.0,
        message: '需要初始化环境',
      );
    } catch (e) {
      return SetupState(
        step: SetupStep.error,
        error: '状态检查失败: $e',
      );
    }
  }

  Future<void> runFullSetup({
    required void Function(SetupState) onProgress,
  }) async {
    try {
      try {
        await NativeBridge.startSetupService();
      } catch (_) {}

      // Step 0: 初始化目录
      onProgress(const SetupState(
        step: SetupStep.checkingStatus,
        progress: 0.0,
        message: '创建目录...',
      ));
      _updateSetupNotification('创建目录...', progress: 2);
      try { await NativeBridge.setupDirs(); } catch (_) {}
      try { await NativeBridge.writeResolv(); } catch (_) {}

      // Step 1: 下载 Alpine rootfs (~3MB, 非常快)
      final arch = await NativeBridge.getArch();
      final rootfsUrl = AppConstants.getRootfsUrl(arch);
      final filesDir = await NativeBridge.getFilesDir();
      final tarPath = '$filesDir/tmp/alpine-rootfs.tar.gz';

      _updateSetupNotification('下载 Alpine rootfs...', progress: 5);
      onProgress(const SetupState(
        step: SetupStep.downloadingRootfs,
        progress: 0.0,
        message: '下载 Alpine Linux 根文件系统...',
      ));

      await _dio.download(
        rootfsUrl,
        tarPath,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            final progress = received / total;
            final mb = (received / 1024 / 1024).toStringAsFixed(1);
            final totalMb = (total / 1024 / 1024).toStringAsFixed(1);
            final notifProgress = 5 + (progress * 25).round();
            _updateSetupNotification(
              '下载 rootfs: $mb / $totalMb MB', progress: notifProgress);
            onProgress(SetupState(
              step: SetupStep.downloadingRootfs,
              progress: progress,
              message: '下载中: $mb MB / $totalMb MB',
            ));
          }
        },
      );

      // Step 2: 解压 rootfs (30-50%)
      _updateSetupNotification('解压 rootfs...', progress: 30);
      onProgress(const SetupState(
        step: SetupStep.extractingRootfs,
        progress: 0.0,
        message: '解压根文件系统...',
      ));
      await NativeBridge.extractRootfs(tarPath);

      // Step 3: 安装基础软件包 (50-95%)
      _updateSetupNotification('安装软件包...', progress: 50);
      onProgress(const SetupState(
        step: SetupStep.installingPackages,
        progress: 0.0,
        message: '安装基础软件包 (bash, python3, curl, git, jq)...',
      ));

      // Alpine 使用 apk 包管理器, 不需要 apt/dpkg
      await NativeBridge.runInProot('apk update');

      onProgress(const SetupState(
        step: SetupStep.installingPackages,
        progress: 0.3,
        message: '安装 bash...',
      ));
      _updateSetupNotification('安装 bash...', progress: 60);
      await NativeBridge.runInProot(
        'apk add --no-cache bash coreutils',
      );

      onProgress(const SetupState(
        step: SetupStep.installingPackages,
        progress: 0.5,
        message: '安装开发工具...',
      ));
      _updateSetupNotification('安装开发工具...', progress: 70);
      await NativeBridge.runInProot(
        'apk add --no-cache python3 py3-pip curl wget git jq ca-certificates',
      );

      onProgress(const SetupState(
        step: SetupStep.installingPackages,
        progress: 0.8,
        message: '安装编译工具...',
      ));
      _updateSetupNotification('安装编译工具...', progress: 80);
      // 可选: 开发工具 (用户可以后续按需安装)
      await NativeBridge.runInProot(
        'apk add --no-cache build-base',
      );

      // 创建工作目录
      await NativeBridge.runInProot(
        'mkdir -p /root/workspace && echo "setup_complete"',
      );

      // 完成
      _updateSetupNotification('初始化完成!', progress: 100);
      _stopSetupService();
      onProgress(const SetupState(
        step: SetupStep.complete,
        progress: 1.0,
        message: '环境初始化完成! 可以开始聊天了。',
      ));
    } on DioException catch (e) {
      _stopSetupService();
      onProgress(SetupState(
        step: SetupStep.error,
        error: '下载失败: ${e.message}。请检查网络连接。',
      ));
    } catch (e) {
      _stopSetupService();
      onProgress(SetupState(
        step: SetupStep.error,
        error: '初始化失败: $e',
      ));
    }
  }
}
```

### 2.6 修改 `setup_state.dart`

**文件**: `flutter_app/lib/models/setup_state.dart`

**修改后**:
```dart
enum SetupStep {
  checkingStatus,
  downloadingRootfs,
  extractingRootfs,
  installingPackages,    // 替换 installingNode + installingOpenClaw + configuringBypass
  complete,
  error,
}

class SetupState {
  final SetupStep step;
  final double progress;
  final String message;
  final String? error;

  const SetupState({
    this.step = SetupStep.checkingStatus,
    this.progress = 0.0,
    this.message = '',
    this.error,
  });

  SetupState copyWith({
    SetupStep? step,
    double? progress,
    String? message,
    String? error,
  }) {
    return SetupState(
      step: step ?? this.step,
      progress: progress ?? this.progress,
      message: message ?? this.message,
      error: error,
    );
  }

  bool get isComplete => step == SetupStep.complete;
  bool get hasError => step == SetupStep.error;

  String get stepLabel {
    switch (step) {
      case SetupStep.checkingStatus:
        return '检查状态...';
      case SetupStep.downloadingRootfs:
        return '下载 Alpine rootfs';
      case SetupStep.extractingRootfs:
        return '解压根文件系统';
      case SetupStep.installingPackages:
        return '安装软件包';
      case SetupStep.complete:
        return '初始化完成';
      case SetupStep.error:
        return '出错';
    }
  }

  int get stepNumber {
    switch (step) {
      case SetupStep.checkingStatus: return 0;
      case SetupStep.downloadingRootfs: return 1;
      case SetupStep.extractingRootfs: return 2;
      case SetupStep.installingPackages: return 3;
      case SetupStep.complete: return 4;
      case SetupStep.error: return -1;
    }
  }

  static const int totalSteps = 4;
}
```

### 2.7 要删除的文件列表

```
# Kotlin 层 — 删除 Gateway/Node/SSH/截屏 相关服务
android/.../GatewayService.kt
android/.../NodeForegroundService.kt
android/.../SshForegroundService.kt
android/.../ScreenCaptureService.kt

# Dart Models — 删除 OpenClaw 特有模型
lib/models/ai_provider.dart
lib/models/gateway_state.dart
lib/models/node_frame.dart
lib/models/node_state.dart
lib/models/optional_package.dart

# Dart Providers — 删除 Gateway/Node Provider
lib/providers/gateway_provider.dart
lib/providers/node_provider.dart
lib/providers/setup_provider.dart

# Dart Services — 删除 OpenClaw 特有服务
lib/services/gateway_service.dart
lib/services/node_service.dart
lib/services/node_ws_service.dart
lib/services/node_identity_service.dart
lib/services/package_service.dart
lib/services/provider_config_service.dart
lib/services/update_service.dart
lib/services/screenshot_service.dart
lib/services/ssh_service.dart
lib/services/capabilities/  (整个目录)

# Dart Screens — 删除 OpenClaw 特有页面
lib/screens/web_dashboard_screen.dart
lib/screens/node_screen.dart
lib/screens/configure_screen.dart
lib/screens/providers_screen.dart
lib/screens/provider_detail_screen.dart
lib/screens/packages_screen.dart
lib/screens/package_install_screen.dart
lib/screens/logs_screen.dart
lib/screens/ssh_screen.dart

# Dart Widgets — 删除 OpenClaw 特有组件
lib/widgets/gateway_controls.dart
lib/widgets/node_controls.dart
lib/widgets/status_card.dart
lib/widgets/terminal_toolbar.dart

# Assets — 删除 OpenClaw 特有资源
assets/bionic_bypass.js
```

---

## 3. Phase 2: Dart Agent Loop + 工具系统 (2 天)

### 3.1 `lib/services/llm_service.dart` — LLM API 客户端

```dart
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

// ══════════════════════════════════════════════════════════════════
// API 格式枚举
// ══════════════════════════════════════════════════════════════════
enum ApiFormat { anthropic, openai }

// ══════════════════════════════════════════════════════════════════
// LLM 配置
// ══════════════════════════════════════════════════════════════════
class LlmConfig {
  final ApiFormat format;
  final String apiKey;
  final String model;
  final String baseUrl;
  final int maxTokens;

  const LlmConfig({
    required this.format,
    required this.apiKey,
    required this.model,
    required this.baseUrl,
    this.maxTokens = 8096,
  });

  /// Anthropic 默认配置
  factory LlmConfig.anthropic({
    required String apiKey,
    String model = 'claude-sonnet-4-20250514',
    String baseUrl = 'https://api.anthropic.com',
    int maxTokens = 8096,
  }) {
    return LlmConfig(
      format: ApiFormat.anthropic,
      apiKey: apiKey,
      model: model,
      baseUrl: baseUrl,
      maxTokens: maxTokens,
    );
  }

  /// OpenAI 格式配置 (也适用于兼容 API 如 DeepSeek, OpenRouter)
  factory LlmConfig.openai({
    required String apiKey,
    required String model,
    String baseUrl = 'https://api.openai.com',
    int maxTokens = 8096,
  }) {
    return LlmConfig(
      format: ApiFormat.openai,
      apiKey: apiKey,
      model: model,
      baseUrl: baseUrl,
      maxTokens: maxTokens,
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// 统一的 LLM 响应结构
// ══════════════════════════════════════════════════════════════════
class LlmResponse {
  final String stopReason; // "end_turn" | "tool_use" | "max_tokens" | "stop"
  final List<ContentBlock> content;

  const LlmResponse({required this.stopReason, required this.content});
}

class ContentBlock {
  final String type; // "text" | "tool_use"
  final String? text;
  final String? toolUseId;
  final String? toolName;
  final Map<String, dynamic>? toolInput;

  const ContentBlock({
    required this.type,
    this.text,
    this.toolUseId,
    this.toolName,
    this.toolInput,
  });

  Map<String, dynamic> toJson() {
    if (type == 'text') {
      return {'type': 'text', 'text': text};
    } else {
      return {
        'type': 'tool_use',
        'id': toolUseId,
        'name': toolName,
        'input': toolInput,
      };
    }
  }
}

// ══════════════════════════════════════════════════════════════════
// 工具定义
// ══════════════════════════════════════════════════════════════════
class ToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  const ToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  /// 转为 Anthropic 格式
  Map<String, dynamic> toAnthropicJson() => {
    'name': name,
    'description': description,
    'input_schema': inputSchema,
  };

  /// 转为 OpenAI 格式
  Map<String, dynamic> toOpenAIJson() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': inputSchema,
    },
  };
}

// ══════════════════════════════════════════════════════════════════
// 流式事件
// ══════════════════════════════════════════════════════════════════
sealed class StreamEvent {}

class TextDelta extends StreamEvent {
  final String text;
  TextDelta(this.text);
}

class ToolUseStart extends StreamEvent {
  final String id;
  final String name;
  ToolUseStart(this.id, this.name);
}

class ToolInputDelta extends StreamEvent {
  final String json;
  ToolInputDelta(this.json);
}

class StreamDone extends StreamEvent {
  final LlmResponse response;
  StreamDone(this.response);
}

class StreamError extends StreamEvent {
  final String message;
  StreamError(this.message);
}

// ══════════════════════════════════════════════════════════════════
// LLM Service 主类
// ══════════════════════════════════════════════════════════════════
class LlmService {
  final LlmConfig config;
  final http.Client _client;

  LlmService(this.config) : _client = http.Client();

  void dispose() => _client.close();

  // ────────────────────────────────────────────────────
  // 非流式请求 (同步等待完整响应)
  // ────────────────────────────────────────────────────
  Future<LlmResponse> chat({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) async {
    switch (config.format) {
      case ApiFormat.anthropic:
        return _anthropicChat(system, messages, tools);
      case ApiFormat.openai:
        return _openaiChat(system, messages, tools);
    }
  }

  // ────────────────────────────────────────────────────
  // 流式请求 (SSE)
  // ────────────────────────────────────────────────────
  Stream<StreamEvent> chatStream({
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<ToolDefinition> tools,
  }) {
    switch (config.format) {
      case ApiFormat.anthropic:
        return _anthropicStream(system, messages, tools);
      case ApiFormat.openai:
        return _openaiStream(system, messages, tools);
    }
  }

  // ════════════════════════════════════════════════════
  // Anthropic 实现
  // ════════════════════════════════════════════════════

  Future<LlmResponse> _anthropicChat(
    String system,
    List<Map<String, dynamic>> messages,
    List<ToolDefinition> tools,
  ) async {
    final url = '${config.baseUrl}/v1/messages';
    final body = _buildAnthropicBody(system, messages, tools, stream: false);

    final response = await _client.post(
      Uri.parse(url),
      headers: _anthropicHeaders(),
      body: jsonEncode(body),
    );

    if (response.statusCode != 200) {
      throw Exception('Anthropic API 错误 (${response.statusCode}): ${response.body}');
    }

    return _parseAnthropicResponse(jsonDecode(response.body));
  }

  Stream<StreamEvent> _anthropicStream(
    String system,
    List<Map<String, dynamic>> messages,
    List<ToolDefinition> tools,
  ) async* {
    final url = '${config.baseUrl}/v1/messages';
    final body = _buildAnthropicBody(system, messages, tools, stream: true);

    final request = http.Request('POST', Uri.parse(url));
    request.headers.addAll(_anthropicHeaders());
    request.body = jsonEncode(body);

    final streamedResponse = await _client.send(request);
    if (streamedResponse.statusCode != 200) {
      final errorBody = await streamedResponse.stream.bytesToString();
      yield StreamError('Anthropic API 错误 (${streamedResponse.statusCode}): $errorBody');
      return;
    }

    // 解析 SSE 流
    final List<ContentBlock> collectedBlocks = [];
    String currentText = '';
    String currentToolId = '';
    String currentToolName = '';
    StringBuffer currentToolInput = StringBuffer();
    String stopReason = 'end_turn';

    await for (final chunk in streamedResponse.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (!chunk.startsWith('data: ')) continue;
      final data = chunk.substring(6).trim();
      if (data == '[DONE]') break;

      try {
        final event = jsonDecode(data) as Map<String, dynamic>;
        final type = event['type'] as String?;

        switch (type) {
          case 'content_block_start':
            final block = event['content_block'] as Map<String, dynamic>;
            if (block['type'] == 'tool_use') {
              currentToolId = block['id'] as String;
              currentToolName = block['name'] as String;
              currentToolInput = StringBuffer();
              yield ToolUseStart(currentToolId, currentToolName);
            }
            break;

          case 'content_block_delta':
            final delta = event['delta'] as Map<String, dynamic>;
            if (delta['type'] == 'text_delta') {
              final text = delta['text'] as String;
              currentText += text;
              yield TextDelta(text);
            } else if (delta['type'] == 'input_json_delta') {
              final json = delta['partial_json'] as String;
              currentToolInput.write(json);
              yield ToolInputDelta(json);
            }
            break;

          case 'content_block_stop':
            final index = event['index'] as int;
            // 确定这个 block 是 text 还是 tool_use
            if (currentToolName.isNotEmpty && currentToolId.isNotEmpty) {
              Map<String, dynamic> input = {};
              try {
                final inputStr = currentToolInput.toString();
                if (inputStr.isNotEmpty) {
                  input = jsonDecode(inputStr);
                }
              } catch (_) {}
              collectedBlocks.add(ContentBlock(
                type: 'tool_use',
                toolUseId: currentToolId,
                toolName: currentToolName,
                toolInput: input,
              ));
              currentToolId = '';
              currentToolName = '';
              currentToolInput = StringBuffer();
            } else if (currentText.isNotEmpty) {
              collectedBlocks.add(ContentBlock(type: 'text', text: currentText));
              currentText = '';
            }
            break;

          case 'message_delta':
            final delta = event['delta'] as Map<String, dynamic>;
            stopReason = delta['stop_reason'] as String? ?? 'end_turn';
            break;

          case 'message_stop':
            break;

          case 'error':
            final error = event['error'] as Map<String, dynamic>;
            yield StreamError(error['message'] as String? ?? '未知错误');
            return;
        }
      } catch (e) {
        // 跳过不可解析的行
        continue;
      }
    }

    // 处理未收集的尾部文本
    if (currentText.isNotEmpty) {
      collectedBlocks.add(ContentBlock(type: 'text', text: currentText));
    }

    yield StreamDone(LlmResponse(
      stopReason: stopReason,
      content: collectedBlocks,
    ));
  }

  Map<String, dynamic> _buildAnthropicBody(
    String system,
    List<Map<String, dynamic>> messages,
    List<ToolDefinition> tools, {
    required bool stream,
  }) {
    final body = <String, dynamic>{
      'model': config.model,
      'max_tokens': config.maxTokens,
      'system': system,
      'messages': messages,
      'stream': stream,
    };
    if (tools.isNotEmpty) {
      body['tools'] = tools.map((t) => t.toAnthropicJson()).toList();
    }
    return body;
  }

  Map<String, String> _anthropicHeaders() => {
    'Content-Type': 'application/json',
    'x-api-key': config.apiKey,
    'anthropic-version': '2023-06-01',
  };

  LlmResponse _parseAnthropicResponse(Map<String, dynamic> json) {
    final stopReason = json['stop_reason'] as String? ?? 'end_turn';
    final content = (json['content'] as List).map<ContentBlock>((block) {
      if (block['type'] == 'text') {
        return ContentBlock(type: 'text', text: block['text']);
      } else if (block['type'] == 'tool_use') {
        return ContentBlock(
          type: 'tool_use',
          toolUseId: block['id'],
          toolName: block['name'],
          toolInput: Map<String, dynamic>.from(block['input']),
        );
      }
      return ContentBlock(type: 'text', text: '');
    }).toList();

    return LlmResponse(stopReason: stopReason, content: content);
  }

  // ════════════════════════════════════════════════════
  // OpenAI 实现
  // ════════════════════════════════════════════════════

  Future<LlmResponse> _openaiChat(
    String system,
    List<Map<String, dynamic>> messages,
    List<ToolDefinition> tools,
  ) async {
    final url = '${config.baseUrl}/v1/chat/completions';
    final body = _buildOpenAIBody(system, messages, tools, stream: false);

    final response = await _client.post(
      Uri.parse(url),
      headers: _openaiHeaders(),
      body: jsonEncode(body),
    );

    if (response.statusCode != 200) {
      throw Exception('OpenAI API 错误 (${response.statusCode}): ${response.body}');
    }

    return _parseOpenAIResponse(jsonDecode(response.body));
  }

  Stream<StreamEvent> _openaiStream(
    String system,
    List<Map<String, dynamic>> messages,
    List<ToolDefinition> tools,
  ) async* {
    final url = '${config.baseUrl}/v1/chat/completions';
    final body = _buildOpenAIBody(system, messages, tools, stream: true);

    final request = http.Request('POST', Uri.parse(url));
    request.headers.addAll(_openaiHeaders());
    request.body = jsonEncode(body);

    final streamedResponse = await _client.send(request);
    if (streamedResponse.statusCode != 200) {
      final errorBody = await streamedResponse.stream.bytesToString();
      yield StreamError('OpenAI API 错误 (${streamedResponse.statusCode}): $errorBody');
      return;
    }

    // 解析 SSE 流
    String currentText = '';
    final List<ContentBlock> collectedBlocks = [];
    // OpenAI tool_calls 收集器: index -> {id, name, arguments}
    final Map<int, Map<String, String>> toolCallsAccum = {};
    String stopReason = 'stop';

    await for (final chunk in streamedResponse.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (!chunk.startsWith('data: ')) continue;
      final data = chunk.substring(6).trim();
      if (data == '[DONE]') break;

      try {
        final event = jsonDecode(data) as Map<String, dynamic>;
        final choices = event['choices'] as List?;
        if (choices == null || choices.isEmpty) continue;
        final choice = choices[0] as Map<String, dynamic>;
        final delta = choice['delta'] as Map<String, dynamic>?;
        final finishReason = choice['finish_reason'] as String?;

        if (finishReason != null) {
          stopReason = finishReason;
        }

        if (delta == null) continue;

        // 文本内容
        final content = delta['content'] as String?;
        if (content != null) {
          currentText += content;
          yield TextDelta(content);
        }

        // 工具调用
        final toolCalls = delta['tool_calls'] as List?;
        if (toolCalls != null) {
          for (final tc in toolCalls) {
            final index = tc['index'] as int;
            toolCallsAccum.putIfAbsent(index, () => {'id': '', 'name': '', 'arguments': ''});
            if (tc['id'] != null) {
              toolCallsAccum[index]!['id'] = tc['id'];
            }
            if (tc['function'] != null) {
              final func = tc['function'] as Map<String, dynamic>;
              if (func['name'] != null) {
                toolCallsAccum[index]!['name'] = func['name'];
                yield ToolUseStart(
                  toolCallsAccum[index]!['id']!,
                  func['name'],
                );
              }
              if (func['arguments'] != null) {
                toolCallsAccum[index]!['arguments'] =
                    toolCallsAccum[index]!['arguments']! + func['arguments'];
                yield ToolInputDelta(func['arguments']);
              }
            }
          }
        }
      } catch (e) {
        continue;
      }
    }

    // 收集 text block
    if (currentText.isNotEmpty) {
      collectedBlocks.add(ContentBlock(type: 'text', text: currentText));
    }

    // 收集 tool_use blocks
    for (final entry in toolCallsAccum.entries) {
      final tc = entry.value;
      Map<String, dynamic> args = {};
      try {
        if (tc['arguments']!.isNotEmpty) {
          args = jsonDecode(tc['arguments']!);
        }
      } catch (_) {}
      collectedBlocks.add(ContentBlock(
        type: 'tool_use',
        toolUseId: tc['id'],
        toolName: tc['name'],
        toolInput: args,
      ));
    }

    // 转换 OpenAI 的 stop_reason
    final mappedStopReason = switch (stopReason) {
      'tool_calls' => 'tool_use',
      'stop' => 'end_turn',
      'length' => 'max_tokens',
      _ => stopReason,
    };

    yield StreamDone(LlmResponse(
      stopReason: mappedStopReason,
      content: collectedBlocks,
    ));
  }

  Map<String, dynamic> _buildOpenAIBody(
    String system,
    List<Map<String, dynamic>> messages,
    List<ToolDefinition> tools, {
    required bool stream,
  }) {
    // 将 Anthropic 格式 messages 转换为 OpenAI 格式
    final openaiMessages = <Map<String, dynamic>>[
      {'role': 'system', 'content': system},
    ];

    for (final msg in messages) {
      openaiMessages.add(_convertMessageToOpenAI(msg));
    }

    final body = <String, dynamic>{
      'model': config.model,
      'max_tokens': config.maxTokens,
      'messages': openaiMessages,
      'stream': stream,
    };
    if (tools.isNotEmpty) {
      body['tools'] = tools.map((t) => t.toOpenAIJson()).toList();
    }
    return body;
  }

  /// 将 Anthropic 格式的 message 转换为 OpenAI 格式
  Map<String, dynamic> _convertMessageToOpenAI(Map<String, dynamic> msg) {
    final role = msg['role'] as String;
    final content = msg['content'];

    // 简单文本消息
    if (content is String) {
      return {'role': role, 'content': content};
    }

    // content 是 List (Anthropic 的 content blocks)
    if (content is List) {
      // 检查是否是 tool_result 列表
      final firstItem = content.isNotEmpty ? content[0] : null;
      if (firstItem is Map && firstItem['type'] == 'tool_result') {
        // OpenAI: 每个 tool_result 变成一条独立的 tool message
        // 这里返回第一个, 调用方需要处理多个
        // 实际上需要在外层展平
        return {
          'role': 'tool',
          'tool_call_id': firstItem['tool_use_id'],
          'content': firstItem['content'] is String
              ? firstItem['content']
              : jsonEncode(firstItem['content']),
        };
      }

      // Assistant 消息包含 text + tool_use
      final textParts = <String>[];
      final toolCalls = <Map<String, dynamic>>[];

      for (final block in content) {
        if (block is Map) {
          if (block['type'] == 'text') {
            textParts.add(block['text'] as String);
          } else if (block['type'] == 'tool_use') {
            toolCalls.add({
              'id': block['id'],
              'type': 'function',
              'function': {
                'name': block['name'],
                'arguments': jsonEncode(block['input']),
              },
            });
          }
        }
      }

      final result = <String, dynamic>{
        'role': role,
        'content': textParts.join('\n'),
      };
      if (toolCalls.isNotEmpty) {
        result['tool_calls'] = toolCalls;
      }
      return result;
    }

    return {'role': role, 'content': content.toString()};
  }

  Map<String, String> _openaiHeaders() => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer ${config.apiKey}',
  };

  LlmResponse _parseOpenAIResponse(Map<String, dynamic> json) {
    final choice = (json['choices'] as List)[0] as Map<String, dynamic>;
    final message = choice['message'] as Map<String, dynamic>;
    final finishReason = choice['finish_reason'] as String? ?? 'stop';

    final blocks = <ContentBlock>[];

    // 文本内容
    final content = message['content'] as String?;
    if (content != null && content.isNotEmpty) {
      blocks.add(ContentBlock(type: 'text', text: content));
    }

    // 工具调用
    final toolCalls = message['tool_calls'] as List?;
    if (toolCalls != null) {
      for (final tc in toolCalls) {
        final func = tc['function'] as Map<String, dynamic>;
        Map<String, dynamic> args = {};
        try {
          args = jsonDecode(func['arguments'] as String);
        } catch (_) {}
        blocks.add(ContentBlock(
          type: 'tool_use',
          toolUseId: tc['id'] as String,
          toolName: func['name'] as String,
          toolInput: args,
        ));
      }
    }

    final mappedStopReason = switch (finishReason) {
      'tool_calls' => 'tool_use',
      'stop' => 'end_turn',
      'length' => 'max_tokens',
      _ => finishReason,
    };

    return LlmResponse(stopReason: mappedStopReason, content: blocks);
  }
}
```

### 3.2 `lib/services/agent_service.dart` — 核心 Agent Loop

```dart
import 'dart:async';
import 'dart:convert';
import 'llm_service.dart';
import 'tools/tool_registry.dart';

// ══════════════════════════════════════════════════════════════════
// Agent 事件 (UI 可订阅)
// ══════════════════════════════════════════════════════════════════
sealed class AgentEvent {}

class AgentThinking extends AgentEvent {}

class AgentTextDelta extends AgentEvent {
  final String text;
  AgentTextDelta(this.text);
}

class AgentToolStart extends AgentEvent {
  final String toolUseId;
  final String toolName;
  final Map<String, dynamic> input;
  AgentToolStart(this.toolUseId, this.toolName, this.input);
}

class AgentToolDone extends AgentEvent {
  final String toolUseId;
  final String output;
  final bool isError;
  AgentToolDone(this.toolUseId, this.output, {this.isError = false});
}

class AgentComplete extends AgentEvent {
  final String finalText;
  AgentComplete(this.finalText);
}

class AgentError extends AgentEvent {
  final String message;
  AgentError(this.message);
}

// ══════════════════════════════════════════════════════════════════
// Agent Service
// ══════════════════════════════════════════════════════════════════
class AgentService {
  final LlmService _llm;
  final ToolRegistry _tools;
  final String _systemPrompt;
  bool _cancelled = false;

  AgentService({
    required LlmService llm,
    required ToolRegistry tools,
    required String systemPrompt,
  })  : _llm = llm,
        _tools = tools,
        _systemPrompt = systemPrompt;

  /// 取消正在运行的 Agent Loop
  void cancel() => _cancelled = true;
  bool get isCancelled => _cancelled;

  /// ── 核心 Agent Loop ──────────────────────────────────────────
  ///
  /// 翻译自 Python 参考实现:
  /// ```python
  /// def agent_loop(messages):
  ///     while True:
  ///         response = client.messages.create(
  ///             model=MODEL, system=SYSTEM, messages=messages,
  ///             tools=TOOLS, max_tokens=8000)
  ///         messages.append({"role": "assistant", "content": response.content})
  ///         if response.stop_reason != "tool_use":
  ///             return
  ///         results = []
  ///         for block in response.content:
  ///             if block.type == "tool_use":
  ///                 output = run_tool(block.name, block.input)
  ///                 results.append({
  ///                     "type": "tool_result",
  ///                     "tool_use_id": block.id,
  ///                     "content": output
  ///                 })
  ///         messages.append({"role": "user", "content": results})
  /// ```
  Stream<AgentEvent> runAgentLoop(
    List<Map<String, dynamic>> messages,
  ) async* {
    _cancelled = false;
    final toolDefs = _tools.getToolDefinitions();

    while (!_cancelled) {
      yield AgentThinking();

      // ── Step 1: 调用 LLM (流式) ────────────────
      LlmResponse? response;
      final textBuffer = StringBuffer();

      try {
        await for (final event in _llm.chatStream(
          system: _systemPrompt,
          messages: messages,
          tools: toolDefs,
        )) {
          if (_cancelled) return;

          switch (event) {
            case TextDelta(:final text):
              textBuffer.write(text);
              yield AgentTextDelta(text);
            case ToolUseStart(:final id, :final name):
              // 工具开始, 等待 input 收集完毕
              break;
            case ToolInputDelta(:final json):
              break;
            case StreamDone(:final response as LlmResponse):
              response = event.response;
            case StreamError(:final message):
              yield AgentError(message);
              return;
            default:
              break;
          }

          // 重新赋值 response (Dart 的 switch 中 response 会被遮蔽)
          if (event is StreamDone) {
            response = event.response;
          }
        }
      } catch (e) {
        yield AgentError('LLM 请求失败: $e');
        return;
      }

      if (response == null) {
        yield AgentError('未收到 LLM 响应');
        return;
      }

      // ── Step 2: 将 assistant 消息追加到历史 ────
      messages.add({
        'role': 'assistant',
        'content': response.content.map((b) => b.toJson()).toList(),
      });

      // ── Step 3: 如果不是 tool_use, 结束循环 ────
      if (response.stopReason != 'tool_use') {
        final finalText = response.content
            .where((b) => b.type == 'text')
            .map((b) => b.text ?? '')
            .join();
        yield AgentComplete(finalText);
        return;
      }

      // ── Step 4: 执行工具 ───────────────────────
      final toolResults = <Map<String, dynamic>>[];

      for (final block in response.content) {
        if (_cancelled) return;
        if (block.type != 'tool_use') continue;

        final toolUseId = block.toolUseId!;
        final toolName = block.toolName!;
        final toolInput = block.toolInput ?? {};

        yield AgentToolStart(toolUseId, toolName, toolInput);

        try {
          final output = await _tools.executeTool(toolName, toolInput);
          yield AgentToolDone(toolUseId, output);
          toolResults.add({
            'type': 'tool_result',
            'tool_use_id': toolUseId,
            'content': output,
          });
        } catch (e) {
          final errorMsg = 'Tool error: $e';
          yield AgentToolDone(toolUseId, errorMsg, isError: true);
          toolResults.add({
            'type': 'tool_result',
            'tool_use_id': toolUseId,
            'content': errorMsg,
            'is_error': true,
          });
        }
      }

      // ── Step 5: 将 tool_result 追加并继续循环 ──
      messages.add({
        'role': 'user',
        'content': toolResults,
      });
    }
  }
}
```

### 3.3 `lib/services/tools/tool_registry.dart` — 工具注册

```dart
import '../../services/llm_service.dart';
import 'bash_tool.dart';
import 'read_file_tool.dart';
import 'write_file_tool.dart';
import 'web_fetch_tool.dart';

/// 工具的基类接口
abstract class Tool {
  String get name;
  String get description;
  Map<String, dynamic> get inputSchema;

  /// 执行工具, 返回文本结果
  Future<String> execute(Map<String, dynamic> input);

  /// 转换为 ToolDefinition (给 LLM 用)
  ToolDefinition toDefinition() => ToolDefinition(
    name: name,
    description: description,
    inputSchema: inputSchema,
  );
}

/// 工具注册表 — 管理所有可用工具
class ToolRegistry {
  final Map<String, Tool> _tools = {};

  ToolRegistry();

  /// 使用默认工具集初始化
  factory ToolRegistry.withDefaults() {
    final registry = ToolRegistry();
    registry.register(BashTool());
    registry.register(ReadFileTool());
    registry.register(WriteFileTool());
    registry.register(WebFetchTool());
    return registry;
  }

  void register(Tool tool) {
    _tools[tool.name] = tool;
  }

  void unregister(String name) {
    _tools.remove(name);
  }

  List<ToolDefinition> getToolDefinitions() {
    return _tools.values.map((t) => t.toDefinition()).toList();
  }

  Future<String> executeTool(String name, Map<String, dynamic> input) async {
    final tool = _tools[name];
    if (tool == null) {
      throw Exception('未知工具: $name');
    }
    return tool.execute(input);
  }

  List<String> get availableTools => _tools.keys.toList();
}
```

### 3.4 `lib/services/tools/bash_tool.dart` — Shell 执行

```dart
import '../native_bridge.dart';
import 'tool_registry.dart';

class BashTool extends Tool {
  @override
  String get name => 'bash';

  @override
  String get description =>
      'Execute a shell command in the Alpine Linux environment. '
      'The command runs inside a proot container. '
      'Use this for system operations, installing packages, running scripts, etc.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'command': {
        'type': 'string',
        'description': 'The bash command to execute',
      },
      'timeout': {
        'type': 'integer',
        'description': 'Timeout in seconds (default: 120)',
      },
    },
    'required': ['command'],
  };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    final command = input['command'] as String;
    final timeout = input['timeout'] as int? ?? 120;

    try {
      final output = await NativeBridge.runInProot(
        command,
        timeout: timeout,
      );
      // 截断过长的输出 (避免占用太多 token)
      if (output.length > 50000) {
        return '${output.substring(0, 50000)}\n\n[输出已截断, 原始长度: ${output.length} 字符]';
      }
      return output;
    } catch (e) {
      return 'Error: $e';
    }
  }
}
```

### 3.5 `lib/services/tools/read_file_tool.dart` — 文件读取

```dart
import '../native_bridge.dart';
import 'tool_registry.dart';

class ReadFileTool extends Tool {
  @override
  String get name => 'read_file';

  @override
  String get description =>
      'Read the contents of a file from the Alpine Linux filesystem. '
      'Provide the absolute path inside the proot environment (e.g., /root/workspace/main.py). '
      'Supports optional line range with offset and limit.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Absolute path to the file (inside proot)',
      },
      'offset': {
        'type': 'integer',
        'description': 'Start reading from this line number (1-based, default: 1)',
      },
      'limit': {
        'type': 'integer',
        'description': 'Maximum number of lines to read (default: 2000)',
      },
    },
    'required': ['path'],
  };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    final path = input['path'] as String;
    final offset = input['offset'] as int? ?? 1;
    final limit = input['limit'] as int? ?? 2000;

    try {
      // 方法1: 直接通过 NativeBridge 读取 rootfs 文件 (去掉开头的 /)
      // 只适用于 rootfs 内部文件
      final rootfsPath = path.startsWith('/') ? path.substring(1) : path;
      final content = await NativeBridge.readRootfsFile(rootfsPath);

      if (content == null) {
        return 'Error: File not found: $path';
      }

      // 应用 offset 和 limit
      final lines = content.split('\n');
      final startLine = (offset - 1).clamp(0, lines.length);
      final endLine = (startLine + limit).clamp(0, lines.length);
      final selectedLines = lines.sublist(startLine, endLine);

      // 带行号输出 (cat -n 风格)
      final buffer = StringBuffer();
      for (int i = 0; i < selectedLines.length; i++) {
        buffer.writeln('${startLine + i + 1}\t${selectedLines[i]}');
      }

      final result = buffer.toString();
      if (result.length > 100000) {
        return '${result.substring(0, 100000)}\n\n[文件已截断]';
      }
      return result;
    } catch (e) {
      return 'Error reading file: $e';
    }
  }
}
```

### 3.6 `lib/services/tools/write_file_tool.dart` — 文件写入

```dart
import '../native_bridge.dart';
import 'tool_registry.dart';

class WriteFileTool extends Tool {
  @override
  String get name => 'write_file';

  @override
  String get description =>
      'Write content to a file in the Alpine Linux filesystem. '
      'Creates the file if it doesn\'t exist, overwrites if it does. '
      'Parent directories are created automatically.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Absolute path for the file (inside proot)',
      },
      'content': {
        'type': 'string',
        'description': 'The content to write to the file',
      },
    },
    'required': ['path', 'content'],
  };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    final path = input['path'] as String;
    final content = input['content'] as String;

    try {
      final rootfsPath = path.startsWith('/') ? path.substring(1) : path;

      // 先创建父目录 (通过 proot 执行 mkdir -p)
      final dir = path.substring(0, path.lastIndexOf('/'));
      await NativeBridge.runInProot('mkdir -p $dir');

      // 写入文件
      await NativeBridge.writeRootfsFile(rootfsPath, content);
      return 'Successfully wrote ${content.length} bytes to $path';
    } catch (e) {
      return 'Error writing file: $e';
    }
  }
}
```

### 3.7 `lib/services/tools/web_fetch_tool.dart` — 网页抓取

```dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'tool_registry.dart';

class WebFetchTool extends Tool {
  @override
  String get name => 'web_fetch';

  @override
  String get description =>
      'Fetch content from a URL. Returns the response body as text. '
      'Useful for reading web pages, APIs, documentation, etc. '
      'Automatically upgrades HTTP to HTTPS.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'url': {
        'type': 'string',
        'description': 'The URL to fetch (will be upgraded to HTTPS if HTTP)',
      },
      'method': {
        'type': 'string',
        'enum': ['GET', 'POST'],
        'description': 'HTTP method (default: GET)',
      },
      'headers': {
        'type': 'object',
        'description': 'Optional HTTP headers',
      },
      'body': {
        'type': 'string',
        'description': 'Request body (for POST requests)',
      },
    },
    'required': ['url'],
  };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    var url = input['url'] as String;
    final method = input['method'] as String? ?? 'GET';
    final headers = input['headers'] as Map<String, dynamic>?;
    final body = input['body'] as String?;

    // 升级 HTTP -> HTTPS
    if (url.startsWith('http://')) {
      url = 'https://${url.substring(7)}';
    }

    try {
      final uri = Uri.parse(url);
      final reqHeaders = headers?.map((k, v) => MapEntry(k, v.toString())) ?? {};

      http.Response response;
      if (method == 'POST') {
        response = await http.post(uri, headers: reqHeaders, body: body)
            .timeout(const Duration(seconds: 30));
      } else {
        response = await http.get(uri, headers: reqHeaders)
            .timeout(const Duration(seconds: 30));
      }

      final result = StringBuffer();
      result.writeln('Status: ${response.statusCode}');
      result.writeln('Content-Type: ${response.headers['content-type'] ?? 'unknown'}');
      result.writeln('---');

      var responseBody = response.body;
      // 截断过长的响应
      if (responseBody.length > 50000) {
        responseBody = '${responseBody.substring(0, 50000)}\n\n[响应已截断]';
      }
      result.write(responseBody);

      return result.toString();
    } catch (e) {
      return 'Error fetching URL: $e';
    }
  }
}
```

---

## 4. Phase 3: 数据模型 + 会话管理 (1 天)

### 4.1 `lib/models/chat_models.dart` — 数据模型

```dart
import 'dart:convert';

// ══════════════════════════════════════════════════════════════════
// 聊天会话
// ══════════════════════════════════════════════════════════════════
class ChatSession {
  final String id;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<ChatMessage> messages;

  ChatSession({
    required this.id,
    this.title = '新对话',
    DateTime? createdAt,
    DateTime? updatedAt,
    List<ChatMessage>? messages,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        messages = messages ?? [];

  /// 自动从第一条用户消息生成标题
  void autoTitle() {
    final firstUserMsg = messages.where((m) => m.role == 'user').firstOrNull;
    if (firstUserMsg != null) {
      final text = firstUserMsg.textContent;
      if (text.isNotEmpty) {
        title = text.length > 50 ? '${text.substring(0, 50)}...' : text;
      }
    }
  }

  /// 转为 LLM API 需要的 messages 格式
  List<Map<String, dynamic>> toApiMessages() {
    return messages.map((m) => m.toApiJson()).toList();
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'messages': messages.map((m) => m.toJson()).toList(),
  };

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    return ChatSession(
      id: json['id'] as String,
      title: json['title'] as String? ?? '新对话',
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      messages: (json['messages'] as List)
          .map((m) => ChatMessage.fromJson(m))
          .toList(),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// 聊天消息
// ══════════════════════════════════════════════════════════════════
class ChatMessage {
  final String role; // "user" | "assistant"
  final List<MessageContent> content;
  final DateTime timestamp;

  ChatMessage({
    required this.role,
    required this.content,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// 便捷构造: 纯文本用户消息
  factory ChatMessage.user(String text) {
    return ChatMessage(
      role: 'user',
      content: [TextContent(text)],
    );
  }

  /// 便捷构造: 从 LLM 响应创建 assistant 消息
  factory ChatMessage.assistant(List<Map<String, dynamic>> contentBlocks) {
    final content = contentBlocks.map((block) {
      switch (block['type']) {
        case 'text':
          return TextContent(block['text'] as String);
        case 'tool_use':
          return ToolUseContent(
            id: block['id'] as String,
            name: block['name'] as String,
            input: Map<String, dynamic>.from(block['input'] ?? {}),
          );
        default:
          return TextContent(block.toString());
      }
    }).toList();

    return ChatMessage(role: 'assistant', content: content.cast<MessageContent>());
  }

  /// 便捷构造: tool_result 消息
  factory ChatMessage.toolResults(List<Map<String, dynamic>> results) {
    final content = results.map((r) => ToolResultContent(
      toolUseId: r['tool_use_id'] as String,
      output: r['content'] as String,
      isError: r['is_error'] as bool? ?? false,
    )).toList();

    return ChatMessage(role: 'user', content: content.cast<MessageContent>());
  }

  /// 获取纯文本内容
  String get textContent {
    return content
        .whereType<TextContent>()
        .map((c) => c.text)
        .join('\n');
  }

  /// 获取工具调用列表
  List<ToolUseContent> get toolUses {
    return content.whereType<ToolUseContent>().toList();
  }

  /// 获取工具结果列表
  List<ToolResultContent> get toolResults {
    return content.whereType<ToolResultContent>().toList();
  }

  /// 转为 API 请求格式
  Map<String, dynamic> toApiJson() {
    if (content.length == 1 && content[0] is TextContent) {
      return {'role': role, 'content': (content[0] as TextContent).text};
    }
    return {
      'role': role,
      'content': content.map((c) => c.toApiJson()).toList(),
    };
  }

  Map<String, dynamic> toJson() => {
    'role': role,
    'timestamp': timestamp.toIso8601String(),
    'content': content.map((c) => c.toJson()).toList(),
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final contentList = json['content'] as List;
    final content = contentList.map((c) {
      final type = c['type'] as String;
      switch (type) {
        case 'text':
          return TextContent(c['text'] as String);
        case 'tool_use':
          return ToolUseContent(
            id: c['id'] as String,
            name: c['name'] as String,
            input: Map<String, dynamic>.from(c['input'] ?? {}),
          );
        case 'tool_result':
          return ToolResultContent(
            toolUseId: c['tool_use_id'] as String,
            output: c['output'] as String,
            isError: c['is_error'] as bool? ?? false,
          );
        default:
          return TextContent(c.toString());
      }
    }).toList();

    return ChatMessage(
      role: json['role'] as String,
      content: content.cast<MessageContent>(),
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// 消息内容类型层次
// ══════════════════════════════════════════════════════════════════
sealed class MessageContent {
  Map<String, dynamic> toApiJson();
  Map<String, dynamic> toJson();
}

class TextContent extends MessageContent {
  final String text;
  TextContent(this.text);

  @override
  Map<String, dynamic> toApiJson() => {'type': 'text', 'text': text};

  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text};
}

class ToolUseContent extends MessageContent {
  final String id;
  final String name;
  final Map<String, dynamic> input;
  String? output;      // 执行后填充 (仅 UI 展示用)
  bool isExecuting;    // 正在执行中
  bool isError;        // 执行出错

  ToolUseContent({
    required this.id,
    required this.name,
    required this.input,
    this.output,
    this.isExecuting = false,
    this.isError = false,
  });

  @override
  Map<String, dynamic> toApiJson() => {
    'type': 'tool_use',
    'id': id,
    'name': name,
    'input': input,
  };

  @override
  Map<String, dynamic> toJson() => {
    'type': 'tool_use',
    'id': id,
    'name': name,
    'input': input,
    'output': output,
    'is_error': isError,
  };
}

class ToolResultContent extends MessageContent {
  final String toolUseId;
  final String output;
  final bool isError;

  ToolResultContent({
    required this.toolUseId,
    required this.output,
    this.isError = false,
  });

  @override
  Map<String, dynamic> toApiJson() => {
    'type': 'tool_result',
    'tool_use_id': toolUseId,
    'content': output,
    if (isError) 'is_error': true,
  };

  @override
  Map<String, dynamic> toJson() => {
    'type': 'tool_result',
    'tool_use_id': toolUseId,
    'output': output,
    'is_error': isError,
  };
}
```

### 4.2 `lib/services/session_storage.dart` — 会话持久化

```dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/chat_models.dart';

/// 使用 SharedPreferences 持久化聊天会话。
/// 选择 SharedPreferences 而非 SQLite 的原因:
/// 1. 无需额外依赖 (sqflite)
/// 2. 对于 <100 个会话的场景足够快
/// 3. 序列化/反序列化比 SQL 更简单
class SessionStorage {
  static const _sessionListKey = 'clawchat_session_ids';
  static const _sessionPrefix = 'clawchat_session_';

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// 获取所有会话 ID (按更新时间倒序)
  Future<List<String>> getSessionIds() async {
    await init();
    return _prefs!.getStringList(_sessionListKey) ?? [];
  }

  /// 获取所有会话摘要 (不加载完整消息)
  Future<List<ChatSession>> getAllSessions() async {
    await init();
    final ids = await getSessionIds();
    final sessions = <ChatSession>[];

    for (final id in ids) {
      final session = await getSession(id);
      if (session != null) {
        sessions.add(session);
      }
    }

    // 按更新时间倒序
    sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sessions;
  }

  /// 加载单个会话
  Future<ChatSession?> getSession(String id) async {
    await init();
    final json = _prefs!.getString('$_sessionPrefix$id');
    if (json == null) return null;
    try {
      return ChatSession.fromJson(jsonDecode(json));
    } catch (e) {
      return null;
    }
  }

  /// 保存会话
  Future<void> saveSession(ChatSession session) async {
    await init();
    session.updatedAt = DateTime.now();

    // 保存会话数据
    await _prefs!.setString(
      '$_sessionPrefix${session.id}',
      jsonEncode(session.toJson()),
    );

    // 更新会话 ID 列表
    final ids = await getSessionIds();
    if (!ids.contains(session.id)) {
      ids.insert(0, session.id);
      await _prefs!.setStringList(_sessionListKey, ids);
    }
  }

  /// 删除会话
  Future<void> deleteSession(String id) async {
    await init();
    await _prefs!.remove('$_sessionPrefix$id');

    final ids = await getSessionIds();
    ids.remove(id);
    await _prefs!.setStringList(_sessionListKey, ids);
  }

  /// 清空所有会话
  Future<void> clearAll() async {
    await init();
    final ids = await getSessionIds();
    for (final id in ids) {
      await _prefs!.remove('$_sessionPrefix$id');
    }
    await _prefs!.remove(_sessionListKey);
  }
}
```

### 4.3 `lib/providers/chat_provider.dart` — 状态管理

```dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../constants.dart';
import '../models/chat_models.dart';
import '../services/agent_service.dart';
import '../services/llm_service.dart';
import '../services/session_storage.dart';
import '../services/tools/tool_registry.dart';
import '../services/preferences_service.dart';

// ══════════════════════════════════════════════════════════════════
// Agent 运行状态
// ══════════════════════════════════════════════════════════════════
enum AgentStatus {
  idle,       // 空闲
  thinking,   // 等待 LLM 响应
  streaming,  // 正在接收流式文本
  tooling,    // 正在执行工具
  error,      // 出错
}

// ══════════════════════════════════════════════════════════════════
// Chat Provider — 核心状态管理
// ══════════════════════════════════════════════════════════════════
class ChatProvider extends ChangeNotifier {
  // ── 公开状态 ────────────────────────────────────
  List<ChatSession> sessions = [];
  ChatSession? currentSession;
  AgentStatus agentStatus = AgentStatus.idle;
  String? errorMessage;
  String streamingText = '';  // 当前流式文本缓冲

  // ── 私有依赖 ────────────────────────────────────
  final SessionStorage _storage = SessionStorage();
  final ToolRegistry _tools = ToolRegistry.withDefaults();
  AgentService? _agent;
  final _uuid = const Uuid();

  // ── 初始化 ──────────────────────────────────────
  Future<void> init() async {
    await _storage.init();
    sessions = await _storage.getAllSessions();
    notifyListeners();
  }

  // ── 会话管理 ─────────────────────────────────────
  Future<ChatSession> createSession() async {
    final session = ChatSession(id: _uuid.v4());
    sessions.insert(0, session);
    currentSession = session;
    await _storage.saveSession(session);
    notifyListeners();
    return session;
  }

  Future<void> selectSession(String id) async {
    currentSession = await _storage.getSession(id);
    notifyListeners();
  }

  Future<void> deleteSession(String id) async {
    await _storage.deleteSession(id);
    sessions.removeWhere((s) => s.id == id);
    if (currentSession?.id == id) {
      currentSession = sessions.isNotEmpty ? sessions.first : null;
    }
    notifyListeners();
  }

  // ── 发送消息 ─────────────────────────────────────
  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    if (agentStatus != AgentStatus.idle) return;

    // 确保有活动会话
    if (currentSession == null) {
      await createSession();
    }

    final session = currentSession!;

    // 添加用户消息
    session.messages.add(ChatMessage.user(text));
    session.autoTitle();
    await _storage.saveSession(session);
    notifyListeners();

    // 创建 LLM 配置
    final prefs = PreferencesService();
    await prefs.init();
    final apiKey = prefs.apiKey;
    if (apiKey == null || apiKey.isEmpty) {
      errorMessage = '请先在设置中配置 API Key';
      agentStatus = AgentStatus.error;
      notifyListeners();
      return;
    }

    final llmConfig = _buildLlmConfig(prefs);
    final llm = LlmService(llmConfig);
    _agent = AgentService(
      llm: llm,
      tools: _tools,
      systemPrompt: prefs.systemPrompt ?? AppConstants.defaultSystemPrompt,
    );

    // 运行 Agent Loop
    agentStatus = AgentStatus.thinking;
    streamingText = '';
    errorMessage = null;
    notifyListeners();

    try {
      await for (final event in _agent!.runAgentLoop(session.toApiMessages())) {
        switch (event) {
          case AgentThinking():
            agentStatus = AgentStatus.thinking;
            notifyListeners();

          case AgentTextDelta(:final text):
            agentStatus = AgentStatus.streaming;
            streamingText += text;
            notifyListeners();

          case AgentToolStart(:final toolUseId, :final toolName, :final input):
            agentStatus = AgentStatus.tooling;
            notifyListeners();

          case AgentToolDone(:final toolUseId, :final output, :final isError):
            // 工具执行完毕
            notifyListeners();

          case AgentComplete(:final finalText):
            agentStatus = AgentStatus.idle;
            streamingText = '';
            // 消息已经在 agent_service 中被添加到 session.toApiMessages()
            // 这里需要同步到 ChatMessage 模型
            _syncMessagesFromApi(session);
            await _storage.saveSession(session);
            notifyListeners();

          case AgentError(:final message):
            agentStatus = AgentStatus.error;
            errorMessage = message;
            notifyListeners();
        }
      }
    } catch (e) {
      agentStatus = AgentStatus.error;
      errorMessage = '$e';
      notifyListeners();
    } finally {
      llm.dispose();
    }
  }

  /// 取消正在运行的 Agent
  void cancelAgent() {
    _agent?.cancel();
    agentStatus = AgentStatus.idle;
    streamingText = '';
    notifyListeners();
  }

  // ── 私有方法 ─────────────────────────────────────

  LlmConfig _buildLlmConfig(PreferencesService prefs) {
    final format = prefs.apiFormat == 'openai'
        ? ApiFormat.openai
        : ApiFormat.anthropic;

    return LlmConfig(
      format: format,
      apiKey: prefs.apiKey!,
      model: prefs.model ?? AppConstants.defaultModel,
      baseUrl: prefs.baseUrl ?? (format == ApiFormat.anthropic
          ? 'https://api.anthropic.com'
          : 'https://api.openai.com'),
      maxTokens: prefs.maxTokens ?? AppConstants.defaultMaxTokens,
    );
  }

  /// 从 API messages 格式反向同步到 ChatMessage 模型
  void _syncMessagesFromApi(ChatSession session) {
    final apiMessages = session.toApiMessages();
    // 重建 messages 列表 (保留原有的, 追加新的)
    final existingCount = session.messages.length;
    for (int i = existingCount; i < apiMessages.length; i++) {
      final msg = apiMessages[i];
      final role = msg['role'] as String;
      final content = msg['content'];

      if (content is String) {
        session.messages.add(ChatMessage(
          role: role,
          content: [TextContent(content)],
        ));
      } else if (content is List) {
        final contentList = content.map<MessageContent>((item) {
          if (item is Map<String, dynamic>) {
            switch (item['type']) {
              case 'text':
                return TextContent(item['text'] as String);
              case 'tool_use':
                return ToolUseContent(
                  id: item['id'] as String,
                  name: item['name'] as String,
                  input: Map<String, dynamic>.from(item['input'] ?? {}),
                );
              case 'tool_result':
                return ToolResultContent(
                  toolUseId: item['tool_use_id'] as String,
                  output: item['content'] as String,
                  isError: item['is_error'] as bool? ?? false,
                );
              default:
                return TextContent(item.toString());
            }
          }
          return TextContent(item.toString());
        }).toList();

        session.messages.add(ChatMessage(
          role: role,
          content: contentList,
        ));
      }
    }
  }
}
```

---

## 5. Phase 4: 聊天界面 (3 天)

### 5.1 `lib/screens/chat_screen.dart` — 主聊天界面

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../app.dart';
import '../models/chat_models.dart';
import '../providers/chat_provider.dart';
import '../widgets/streaming_text.dart';
import '../widgets/tool_call_card.dart';
import '../widgets/agent_status_bar.dart';
import 'chat_sessions_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _sendMessage() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();
    context.read<ChatProvider>().sendMessage(text);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Consumer<ChatProvider>(
          builder: (_, provider, __) {
            return Text(
              provider.currentSession?.title ?? 'ClawChat',
              overflow: TextOverflow.ellipsis,
            );
          },
        ),
        leading: IconButton(
          icon: const Icon(Icons.menu),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ChatSessionsScreen()),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新对话',
            onPressed: () => context.read<ChatProvider>().createSession(),
          ),
        ],
      ),
      body: Column(
        children: [
          // Agent 状态栏
          const AgentStatusBar(),

          // 消息列表
          Expanded(
            child: Consumer<ChatProvider>(
              builder: (_, provider, __) {
                final messages = provider.currentSession?.messages ?? [];

                if (messages.isEmpty) {
                  return _buildEmptyState(theme);
                }

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  itemCount: messages.length + (provider.streamingText.isNotEmpty ? 1 : 0),
                  itemBuilder: (context, index) {
                    // 流式文本 (最后一项)
                    if (index == messages.length && provider.streamingText.isNotEmpty) {
                      return _buildStreamingBubble(provider.streamingText, theme);
                    }

                    final message = messages[index];
                    return _buildMessageBubble(message, theme);
                  },
                );
              },
            ),
          ),

          // 输入区域
          _buildInputArea(theme),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.chat_bubble_outline, size: 64,
              color: theme.colorScheme.onSurfaceVariant.withAlpha(100)),
          const SizedBox(height: 16),
          Text('发送消息开始对话',
              style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Text('AI 助手可以执行命令、读写文件、访问网页',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message, ThemeData theme) {
    final isUser = message.role == 'user';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // 角色标签
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              isUser ? '你' : 'AI',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),

          // 内容
          for (final content in message.content)
            _buildContentBlock(content, isUser, theme),
        ],
      ),
    );
  }

  Widget _buildContentBlock(MessageContent content, bool isUser, ThemeData theme) {
    switch (content) {
      case TextContent(:final text):
        return Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.85,
          ),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isUser
                ? AppColors.accent.withAlpha(20)
                : theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isUser
                  ? AppColors.accent.withAlpha(50)
                  : theme.colorScheme.outline.withAlpha(50),
            ),
          ),
          child: StreamingText(text: text),
        );

      case ToolUseContent():
        return ToolCallCard(toolUse: content);

      case ToolResultContent():
        // tool_result 一般不单独展示, 包含在 ToolCallCard 中
        return const SizedBox.shrink();
    }
  }

  Widget _buildStreamingBubble(String text, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('AI',
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600)),
          ),
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.85,
            ),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.outline.withAlpha(50),
              ),
            ),
            child: StreamingText(text: text, isStreaming: true),
          ),
        ],
      ),
    );
  }

  Widget _buildInputArea(ThemeData theme) {
    return Consumer<ChatProvider>(
      builder: (_, provider, __) {
        final isRunning = provider.agentStatus != AgentStatus.idle &&
            provider.agentStatus != AgentStatus.error;

        return Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            border: Border(
              top: BorderSide(color: theme.colorScheme.outline.withAlpha(50)),
            ),
          ),
          child: SafeArea(
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    focusNode: _focusNode,
                    enabled: !isRunning,
                    maxLines: 5,
                    minLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                    decoration: InputDecoration(
                      hintText: isRunning ? 'AI 正在处理...' : '输入消息...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (isRunning)
                  IconButton.filled(
                    onPressed: provider.cancelAgent,
                    icon: const Icon(Icons.stop),
                    style: IconButton.styleFrom(
                      backgroundColor: AppColors.statusRed,
                    ),
                  )
                else
                  IconButton.filled(
                    onPressed: _sendMessage,
                    icon: const Icon(Icons.send),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
```

### 5.2 `lib/screens/chat_sessions_screen.dart` — 会话列表

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/chat_provider.dart';

class ChatSessionsScreen extends StatelessWidget {
  const ChatSessionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('对话记录'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新对话',
            onPressed: () {
              context.read<ChatProvider>().createSession();
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: Consumer<ChatProvider>(
        builder: (_, provider, __) {
          final sessions = provider.sessions;

          if (sessions.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.forum_outlined, size: 48,
                      color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(height: 16),
                  Text('暂无对话',
                      style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            );
          }

          return ListView.builder(
            itemCount: sessions.length,
            itemBuilder: (context, index) {
              final session = sessions[index];
              final isSelected = session.id == provider.currentSession?.id;

              return Dismissible(
                key: Key(session.id),
                direction: DismissDirection.endToStart,
                confirmDismiss: (_) async {
                  return await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('删除对话'),
                      content: Text('确定删除 "${session.title}" ?'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('删除'),
                        ),
                      ],
                    ),
                  );
                },
                onDismissed: (_) => provider.deleteSession(session.id),
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 16),
                  color: theme.colorScheme.error,
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                child: ListTile(
                  title: Text(
                    session.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${session.messages.length} 条消息 | ${_formatTime(session.updatedAt)}',
                    style: theme.textTheme.bodySmall,
                  ),
                  leading: Icon(
                    Icons.chat_bubble_outline,
                    color: isSelected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  selected: isSelected,
                  onTap: () {
                    provider.selectSession(session.id);
                    Navigator.of(context).pop();
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${dt.month}/${dt.day}';
  }
}
```

### 5.3 `lib/widgets/tool_call_card.dart` — 工具调用卡片

```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/chat_models.dart';
import 'code_block.dart';

class ToolCallCard extends StatefulWidget {
  final ToolUseContent toolUse;

  const ToolCallCard({super.key, required this.toolUse});

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _expanded = false;

  IconData _getToolIcon() {
    switch (widget.toolUse.name) {
      case 'bash':
        return Icons.terminal;
      case 'read_file':
        return Icons.description;
      case 'write_file':
        return Icons.edit_document;
      case 'web_fetch':
        return Icons.language;
      default:
        return Icons.build;
    }
  }

  String _getToolLabel() {
    switch (widget.toolUse.name) {
      case 'bash':
        return widget.toolUse.input['command'] as String? ?? 'Shell';
      case 'read_file':
        return widget.toolUse.input['path'] as String? ?? '读取文件';
      case 'write_file':
        return widget.toolUse.input['path'] as String? ?? '写入文件';
      case 'web_fetch':
        return widget.toolUse.input['url'] as String? ?? '网页请求';
      default:
        return widget.toolUse.name;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isExecuting = widget.toolUse.isExecuting;
    final isError = widget.toolUse.isError;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isError
              ? theme.colorScheme.error.withAlpha(100)
              : theme.colorScheme.outline.withAlpha(50),
        ),
        color: theme.colorScheme.surface,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头部: 工具名称 + 状态
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(_getToolIcon(), size: 16,
                      color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _getToolLabel(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isExecuting)
                    const SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (isError)
                    Icon(Icons.error_outline, size: 16,
                        color: theme.colorScheme.error)
                  else
                    Icon(Icons.check_circle_outline, size: 16,
                        color: Colors.green.shade400),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),

          // 展开内容: input + output
          if (_expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Input', style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  )),
                  const SizedBox(height: 4),
                  CodeBlock(
                    code: const JsonEncoder.withIndent('  ')
                        .convert(widget.toolUse.input),
                    language: 'json',
                  ),
                  if (widget.toolUse.output != null) ...[
                    const SizedBox(height: 12),
                    Text('Output', style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    )),
                    const SizedBox(height: 4),
                    CodeBlock(
                      code: widget.toolUse.output!,
                      language: 'text',
                      maxLines: 20,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
```

### 5.4 `lib/widgets/streaming_text.dart` — 流式 Markdown 渲染

```dart
import 'package:flutter/material.dart';

/// 流式文本渲染组件
/// 支持基本的 Markdown: **粗体**, `行内代码`, ```代码块```
class StreamingText extends StatelessWidget {
  final String text;
  final bool isStreaming;

  const StreamingText({
    super.key,
    required this.text,
    this.isStreaming = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 简单的 Markdown 渲染
    // 生产级应该使用 flutter_markdown 包, 但这里保持轻量
    return SelectableText.rich(
      _buildTextSpan(text, theme),
      style: theme.textTheme.bodyMedium,
    );
  }

  TextSpan _buildTextSpan(String text, ThemeData theme) {
    final spans = <InlineSpan>[];

    // 用正则匹配 markdown 语法
    final codeBlockRegex = RegExp(r'```(\w*)\n([\s\S]*?)```');
    final inlineCodeRegex = RegExp(r'`([^`]+)`');
    final boldRegex = RegExp(r'\*\*(.+?)\*\*');

    int lastEnd = 0;
    final allMatches = <_MatchInfo>[];

    // 收集所有匹配
    for (final match in codeBlockRegex.allMatches(text)) {
      allMatches.add(_MatchInfo(match.start, match.end, 'codeblock', match));
    }
    for (final match in inlineCodeRegex.allMatches(text)) {
      // 避免和 codeblock 重叠
      if (!allMatches.any((m) => match.start >= m.start && match.end <= m.end)) {
        allMatches.add(_MatchInfo(match.start, match.end, 'inline', match));
      }
    }
    for (final match in boldRegex.allMatches(text)) {
      if (!allMatches.any((m) => match.start >= m.start && match.end <= m.end)) {
        allMatches.add(_MatchInfo(match.start, match.end, 'bold', match));
      }
    }

    allMatches.sort((a, b) => a.start.compareTo(b.start));

    for (final info in allMatches) {
      // 之前的普通文本
      if (info.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, info.start)));
      }

      switch (info.type) {
        case 'codeblock':
          spans.add(TextSpan(
            text: info.match.group(2),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ));
        case 'inline':
          spans.add(TextSpan(
            text: info.match.group(1),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              color: theme.colorScheme.primary,
            ),
          ));
        case 'bold':
          spans.add(TextSpan(
            text: info.match.group(1),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ));
      }

      lastEnd = info.end;
    }

    // 剩余文本
    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }

    // 流式光标
    if (isStreaming) {
      spans.add(TextSpan(
        text: '▌', // 闪烁块光标
        style: TextStyle(color: theme.colorScheme.primary),
      ));
    }

    return TextSpan(children: spans);
  }
}

class _MatchInfo {
  final int start;
  final int end;
  final String type;
  final RegExpMatch match;

  _MatchInfo(this.start, this.end, this.type, this.match);
}
```

### 5.5 `lib/widgets/code_block.dart` — 代码展示

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CodeBlock extends StatelessWidget {
  final String code;
  final String language;
  final int maxLines;

  const CodeBlock({
    super.key,
    required this.code,
    this.language = '',
    this.maxLines = 50,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 截断过长的代码
    final lines = code.split('\n');
    final displayCode = lines.length > maxLines
        ? '${lines.take(maxLines).join('\n')}\n\n... (${lines.length - maxLines} lines omitted)'
        : code;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部栏: 语言标签 + 复制按钮
          if (language.isNotEmpty || code.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: theme.colorScheme.outline.withAlpha(30),
                  ),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (language.isNotEmpty)
                    Text(language, style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    )),
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: code));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('已复制'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.copy, size: 14,
                            color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Text('复制', style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        )),
                      ],
                    ),
                  ),
                ],
              ),
            ),

          // 代码内容
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              displayCode,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: theme.colorScheme.onSurface,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

### 5.6 `lib/widgets/agent_status_bar.dart` — Agent 状态指示

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/chat_provider.dart';

class AgentStatusBar extends StatelessWidget {
  const AgentStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Consumer<ChatProvider>(
      builder: (_, provider, __) {
        if (provider.agentStatus == AgentStatus.idle) {
          return const SizedBox.shrink();
        }

        final (icon, label, color) = switch (provider.agentStatus) {
          AgentStatus.thinking => (Icons.psychology, '思考中...', theme.colorScheme.primary),
          AgentStatus.streaming => (Icons.edit, '生成回复...', theme.colorScheme.primary),
          AgentStatus.tooling => (Icons.build, '执行工具...', Colors.orange),
          AgentStatus.error => (Icons.error_outline, provider.errorMessage ?? '出错', theme.colorScheme.error),
          _ => (Icons.hourglass_empty, '处理中...', theme.colorScheme.primary),
        };

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: color.withAlpha(15),
            border: Border(
              bottom: BorderSide(color: color.withAlpha(50)),
            ),
          ),
          child: Row(
            children: [
              if (provider.agentStatus != AgentStatus.error)
                SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color,
                  ),
                )
              else
                Icon(icon, size: 14, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(color: color),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (provider.agentStatus != AgentStatus.error)
                TextButton(
                  onPressed: provider.cancelAgent,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28),
                  ),
                  child: Text('取消', style: TextStyle(color: color, fontSize: 12)),
                ),
            ],
          ),
        );
      },
    );
  }
}
```

---

## 6. Phase 5: 导航 + 设置 + 打磨 (2 天)

### 6.1 修改 `dashboard_screen.dart`

将 Dashboard 改为主页入口, 提供「聊天」入口和「终端」入口。

**修改后**:
```dart
import 'package:flutter/material.dart';
import '../constants.dart';
import 'chat_screen.dart';
import 'terminal_screen.dart';
import 'settings_screen.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // 直接跳转到聊天界面
    // 如果需要 Dashboard 作为入口, 可以保留这个页面
    // 否则在 app.dart 中直接设置 ChatScreen 为首页
    return const ChatScreen();
  }
}
```

### 6.2 修改 `settings_screen.dart`

精简为 API Key 配置 + 系统信息。

**修改后** (关键部分):
```dart
import 'package:flutter/material.dart';
import '../app.dart';
import '../constants.dart';
import '../services/native_bridge.dart';
import '../services/preferences_service.dart';
import 'setup_wizard_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _prefs = PreferencesService();
  final _apiKeyController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _modelController = TextEditingController();
  String _apiFormat = 'anthropic';
  bool _loading = true;
  String _arch = '';
  Map<String, dynamic> _status = {};

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    await _prefs.init();
    _apiKeyController.text = _prefs.apiKey ?? '';
    _baseUrlController.text = _prefs.baseUrl ?? '';
    _modelController.text = _prefs.model ?? AppConstants.defaultModel;
    _apiFormat = _prefs.apiFormat ?? 'anthropic';

    try {
      final arch = await NativeBridge.getArch();
      final status = await NativeBridge.getBootstrapStatus();
      setState(() {
        _arch = arch;
        _status = status;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  void _saveSettings() {
    _prefs.apiKey = _apiKeyController.text.trim().isNotEmpty
        ? _apiKeyController.text.trim()
        : null;
    _prefs.baseUrl = _baseUrlController.text.trim().isNotEmpty
        ? _baseUrlController.text.trim()
        : null;
    _prefs.model = _modelController.text.trim().isNotEmpty
        ? _modelController.text.trim()
        : null;
    _prefs.apiFormat = _apiFormat;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('设置已保存')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                _sectionHeader(theme, 'API 配置'),

                // API 格式选择
                ListTile(
                  title: const Text('API 格式'),
                  subtitle: Text(_apiFormat == 'anthropic' ? 'Anthropic' : 'OpenAI 兼容'),
                  trailing: DropdownButton<String>(
                    value: _apiFormat,
                    items: const [
                      DropdownMenuItem(value: 'anthropic', child: Text('Anthropic')),
                      DropdownMenuItem(value: 'openai', child: Text('OpenAI 兼容')),
                    ],
                    onChanged: (v) => setState(() => _apiFormat = v!),
                  ),
                ),

                // API Key
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: TextField(
                    controller: _apiKeyController,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: 'API Key',
                      hintText: _apiFormat == 'anthropic'
                          ? 'sk-ant-...'
                          : 'sk-...',
                    ),
                  ),
                ),

                // Base URL
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: TextField(
                    controller: _baseUrlController,
                    decoration: InputDecoration(
                      labelText: 'Base URL (可选)',
                      hintText: _apiFormat == 'anthropic'
                          ? 'https://api.anthropic.com'
                          : 'https://api.openai.com',
                    ),
                  ),
                ),

                // 模型名称
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: TextField(
                    controller: _modelController,
                    decoration: InputDecoration(
                      labelText: '模型',
                      hintText: AppConstants.defaultModel,
                    ),
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: FilledButton(
                    onPressed: _saveSettings,
                    child: const Text('保存设置'),
                  ),
                ),

                const Divider(),
                _sectionHeader(theme, '系统信息'),

                ListTile(
                  title: const Text('架构'),
                  subtitle: Text(_arch),
                  leading: const Icon(Icons.memory),
                ),
                ListTile(
                  title: const Text('Rootfs'),
                  subtitle: Text(_status['rootfsExists'] == true ? '已安装' : '未安装'),
                  leading: const Icon(Icons.storage),
                ),
                ListTile(
                  title: const Text('Python3'),
                  subtitle: Text(_status['pythonInstalled'] == true ? '已安装' : '未安装'),
                  leading: const Icon(Icons.code),
                ),

                const Divider(),
                _sectionHeader(theme, '维护'),

                ListTile(
                  title: const Text('重新初始化'),
                  subtitle: const Text('重新安装 Alpine 环境'),
                  leading: const Icon(Icons.build),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const SetupWizardScreen()),
                  ),
                ),

                const Divider(),
                _sectionHeader(theme, '关于'),
                ListTile(
                  title: const Text('ClawChat'),
                  subtitle: Text('v${AppConstants.version}'),
                  leading: const Icon(Icons.info_outline),
                ),
              ],
            ),
    );
  }

  Widget _sectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelController.dispose();
    super.dispose();
  }
}
```

### 6.3 修改 `onboarding_screen.dart`

将终端式 onboarding 改为原生 Flutter 表单。

**修改后** (核心部分):
```dart
import 'package:flutter/material.dart';
import '../constants.dart';
import '../services/preferences_service.dart';
import 'chat_screen.dart';

class OnboardingScreen extends StatefulWidget {
  final bool isFirstRun;
  const OnboardingScreen({super.key, this.isFirstRun = false});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _apiKeyController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _modelController = TextEditingController();
  String _apiFormat = 'anthropic';
  int _currentStep = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('欢迎使用 ClawChat'),
        automaticallyImplyLeading: !widget.isFirstRun,
      ),
      body: Stepper(
        currentStep: _currentStep,
        onStepContinue: _onStepContinue,
        onStepCancel: _currentStep > 0
            ? () => setState(() => _currentStep--)
            : null,
        steps: [
          Step(
            title: const Text('选择 API 格式'),
            content: Column(
              children: [
                RadioListTile<String>(
                  title: const Text('Anthropic (Claude)'),
                  subtitle: const Text('直接使用 Anthropic API'),
                  value: 'anthropic',
                  groupValue: _apiFormat,
                  onChanged: (v) => setState(() => _apiFormat = v!),
                ),
                RadioListTile<String>(
                  title: const Text('OpenAI 兼容'),
                  subtitle: const Text('支持 OpenAI, DeepSeek, OpenRouter 等'),
                  value: 'openai',
                  groupValue: _apiFormat,
                  onChanged: (v) => setState(() => _apiFormat = v!),
                ),
              ],
            ),
          ),
          Step(
            title: const Text('输入 API Key'),
            content: Column(
              children: [
                TextField(
                  controller: _apiKeyController,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    hintText: _apiFormat == 'anthropic'
                        ? 'sk-ant-...'
                        : 'sk-...',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _baseUrlController,
                  decoration: InputDecoration(
                    labelText: 'Base URL (留空使用默认)',
                    hintText: _apiFormat == 'anthropic'
                        ? 'https://api.anthropic.com'
                        : 'https://api.openai.com',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _modelController,
                  decoration: InputDecoration(
                    labelText: '模型名称',
                    hintText: AppConstants.defaultModel,
                  ),
                ),
              ],
            ),
          ),
          Step(
            title: const Text('完成'),
            content: const Text('一切就绪! 点击完成开始使用 ClawChat。'),
          ),
        ],
      ),
    );
  }

  Future<void> _onStepContinue() async {
    if (_currentStep < 2) {
      setState(() => _currentStep++);
      return;
    }

    // 最后一步: 保存设置
    final prefs = PreferencesService();
    await prefs.init();
    prefs.apiFormat = _apiFormat;
    prefs.apiKey = _apiKeyController.text.trim().isNotEmpty
        ? _apiKeyController.text.trim()
        : null;
    prefs.baseUrl = _baseUrlController.text.trim().isNotEmpty
        ? _baseUrlController.text.trim()
        : null;
    prefs.model = _modelController.text.trim().isNotEmpty
        ? _modelController.text.trim()
        : null;
    prefs.setupComplete = true;
    prefs.isFirstRun = false;

    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ChatScreen()),
      );
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelController.dispose();
    super.dispose();
  }
}
```

### 6.4 修改 `app.dart`

**修改后** (关键部分):
```dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'providers/chat_provider.dart';
import 'screens/splash_screen.dart';

class ClawChatApp extends StatelessWidget {     // 重命名 OpenClawApp -> ClawChatApp
  const ClawChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ChatProvider()),
        // 删除: SetupProvider, GatewayProvider, NodeProvider
      ],
      child: MaterialApp(
        title: 'ClawChat',
        debugShowCheckedModeBanner: false,
        theme: _buildLightTheme(),
        darkTheme: _buildDarkTheme(),
        themeMode: ThemeMode.system,
        home: const SplashScreen(),
      ),
    );
  }

  // ... 保留主题代码 (Light + Dark), 将品牌色从红色改为蓝色 (可选) ...
}
```

### 6.5 修改 `preferences_service.dart`

需要增加 API 配置相关字段:

```dart
// 在 PreferencesService 中添加:
String? get apiKey => _prefs?.getString('api_key');
set apiKey(String? v) => v != null
    ? _prefs?.setString('api_key', v)
    : _prefs?.remove('api_key');

String? get apiFormat => _prefs?.getString('api_format');
set apiFormat(String? v) => v != null
    ? _prefs?.setString('api_format', v)
    : _prefs?.remove('api_format');

String? get baseUrl => _prefs?.getString('base_url');
set baseUrl(String? v) => v != null
    ? _prefs?.setString('base_url', v)
    : _prefs?.remove('base_url');

String? get model => _prefs?.getString('model');
set model(String? v) => v != null
    ? _prefs?.setString('model', v)
    : _prefs?.remove('model');

int? get maxTokens => _prefs?.getInt('max_tokens');
set maxTokens(int? v) => v != null
    ? _prefs?.setInt('max_tokens', v)
    : _prefs?.remove('max_tokens');

String? get systemPrompt => _prefs?.getString('system_prompt');
set systemPrompt(String? v) => v != null
    ? _prefs?.setString('system_prompt', v)
    : _prefs?.remove('system_prompt');
```

### 6.6 修改 `pubspec.yaml`

```yaml
name: clawchat
description: ClawChat - AI Agent Chat on Android with embedded Alpine Linux.
publish_to: 'none'
version: 2.0.0+1

environment:
  sdk: '>=3.2.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter
  # ── 保留 ──
  xterm: ^4.0.0              # 终端模拟器 (保留 Terminal 页面)
  flutter_pty: ^0.4.2         # PTY 支持
  dio: ^5.4.0                 # HTTP 下载 (带进度)
  http: ^1.2.0                # HTTP 请求 (LLM API)
  provider: ^6.1.0            # 状态管理
  shared_preferences: ^2.2.0  # 本地存储
  path_provider: ^2.1.0       # 路径
  permission_handler: ^11.3.0 # 权限
  url_launcher: ^6.2.0        # 打开链接
  google_fonts: ^6.1.0        # 字体
  uuid: ^4.2.0                # 会话 ID 生成

  # ── 删除 ──
  # webview_flutter: ^4.4.0   # 不再需要 WebView
  # web_socket_channel: ^3.0.0 # 不再需要 WebSocket
  # cryptography: ^2.7.0       # 不再需要加密
  # camera: ^0.11.0            # 不再需要摄像头
  # geolocator: ^12.0.0        # 不再需要定位
  # flutter_blue_plus: ^1.32.0 # 不再需要蓝牙
  # usb_serial: ^0.5.1         # 不再需要串口

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^5.0.0

flutter:
  uses-material-design: true
  assets:
    - assets/ic_launcher.png
    - assets/resolv.conf
    # 删除: assets/bionic_bypass.js
  fonts:
    - family: DejaVuSansMono
      fonts:
        - asset: assets/fonts/DejaVuSansMono.ttf
        - asset: assets/fonts/DejaVuSansMono-Bold.ttf
          weight: 700
```

---

## 7. API 数据结构详解

### 7.1 Anthropic Messages API

#### 请求 (带 tools):

```json
{
  "model": "claude-sonnet-4-20250514",
  "max_tokens": 8096,
  "system": "You are a helpful AI assistant...",
  "messages": [
    {
      "role": "user",
      "content": "列出当前目录的文件"
    }
  ],
  "tools": [
    {
      "name": "bash",
      "description": "Execute a shell command in the Alpine Linux environment.",
      "input_schema": {
        "type": "object",
        "properties": {
          "command": {
            "type": "string",
            "description": "The bash command to execute"
          },
          "timeout": {
            "type": "integer",
            "description": "Timeout in seconds (default: 120)"
          }
        },
        "required": ["command"]
      }
    },
    {
      "name": "read_file",
      "description": "Read the contents of a file.",
      "input_schema": {
        "type": "object",
        "properties": {
          "path": { "type": "string", "description": "Absolute path to the file" },
          "offset": { "type": "integer", "description": "Start line (1-based)" },
          "limit": { "type": "integer", "description": "Max lines to read" }
        },
        "required": ["path"]
      }
    }
  ],
  "stream": false
}
```

#### 响应 (tool_use):

```json
{
  "id": "msg_01XBr...",
  "type": "message",
  "role": "assistant",
  "model": "claude-sonnet-4-20250514",
  "stop_reason": "tool_use",
  "content": [
    {
      "type": "text",
      "text": "我来查看一下当前目录的文件。"
    },
    {
      "type": "tool_use",
      "id": "toolu_01A...",
      "name": "bash",
      "input": {
        "command": "ls -la /root/workspace"
      }
    }
  ],
  "usage": {
    "input_tokens": 350,
    "output_tokens": 120
  }
}
```

#### tool_result 提交格式:

```json
{
  "role": "user",
  "content": [
    {
      "type": "tool_result",
      "tool_use_id": "toolu_01A...",
      "content": "total 8\ndrwxr-xr-x 2 root root 4096 May 11 main.py\n-rw-r--r-- 1 root root 1234 May 11 README.md"
    }
  ]
}
```

#### 错误的 tool_result:

```json
{
  "role": "user",
  "content": [
    {
      "type": "tool_result",
      "tool_use_id": "toolu_01A...",
      "content": "Error: Command failed (exit code 1): ls: cannot access '/nonexistent': No such file or directory",
      "is_error": true
    }
  ]
}
```

### 7.2 OpenAI Chat Completions API

#### 请求 (带 tools):

```json
{
  "model": "gpt-4o",
  "max_tokens": 8096,
  "messages": [
    {
      "role": "system",
      "content": "You are a helpful AI assistant..."
    },
    {
      "role": "user",
      "content": "列出当前目录的文件"
    }
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "bash",
        "description": "Execute a shell command in the Alpine Linux environment.",
        "parameters": {
          "type": "object",
          "properties": {
            "command": {
              "type": "string",
              "description": "The bash command to execute"
            },
            "timeout": {
              "type": "integer",
              "description": "Timeout in seconds (default: 120)"
            }
          },
          "required": ["command"]
        }
      }
    }
  ],
  "stream": false
}
```

#### 响应 (tool_calls):

```json
{
  "id": "chatcmpl-abc123",
  "object": "chat.completion",
  "model": "gpt-4o",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "我来查看一下当前目录的文件。",
        "tool_calls": [
          {
            "id": "call_abc123",
            "type": "function",
            "function": {
              "name": "bash",
              "arguments": "{\"command\": \"ls -la /root/workspace\"}"
            }
          }
        ]
      },
      "finish_reason": "tool_calls"
    }
  ],
  "usage": {
    "prompt_tokens": 350,
    "completion_tokens": 120,
    "total_tokens": 470
  }
}
```

#### tool 角色消息提交:

```json
{
  "role": "tool",
  "tool_call_id": "call_abc123",
  "content": "total 8\ndrwxr-xr-x 2 root root 4096 May 11 main.py\n-rw-r--r-- 1 root root 1234 May 11 README.md"
}
```

### 7.3 SSE 流式格式

#### Anthropic SSE 格式:

```
event: message_start
data: {"type":"message_start","message":{"id":"msg_01...","type":"message","role":"assistant","model":"claude-sonnet-4-20250514","content":[],"stop_reason":null}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"我来"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"查看"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01A...","name":"bash"}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"command\":"}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" \"ls -la\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":1}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":120}}

event: message_stop
data: {"type":"message_stop"}
```

#### OpenAI SSE 格式:

```
data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"我来"},"finish_reason":null}]}

data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"查看"},"finish_reason":null}]}

data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"bash","arguments":""}}]},"finish_reason":null}]}

data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"command\":"}}]},"finish_reason":null}]}

data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":" \"ls -la\"}"}}]},"finish_reason":null}]}

data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

data: [DONE]
```

---

## 8. 文件清单

### 8.1 新建文件 (11 个)

| 文件路径 | 说明 | Phase |
|---------|------|-------|
| `lib/services/llm_service.dart` | LLM API 客户端 (Anthropic + OpenAI, 流式/非流式) | 2 |
| `lib/services/agent_service.dart` | Agent Loop 核心逻辑 | 2 |
| `lib/services/tools/tool_registry.dart` | 工具注册和路由 | 2 |
| `lib/services/tools/bash_tool.dart` | Shell 命令执行 | 2 |
| `lib/services/tools/read_file_tool.dart` | 文件读取 | 2 |
| `lib/services/tools/write_file_tool.dart` | 文件写入 | 2 |
| `lib/services/tools/web_fetch_tool.dart` | HTTP 请求 | 2 |
| `lib/models/chat_models.dart` | ChatSession, ChatMessage, ContentBlock | 3 |
| `lib/services/session_storage.dart` | SharedPreferences 持久化 | 3 |
| `lib/providers/chat_provider.dart` | 核心状态管理 | 3 |
| `lib/screens/chat_screen.dart` | 主聊天界面 | 4 |
| `lib/screens/chat_sessions_screen.dart` | 会话列表 | 4 |
| `lib/widgets/tool_call_card.dart` | 可折叠工具调用卡片 | 4 |
| `lib/widgets/streaming_text.dart` | 流式 Markdown 渲染 | 4 |
| `lib/widgets/code_block.dart` | 语法高亮代码块 | 4 |
| `lib/widgets/agent_status_bar.dart` | Agent 运行状态栏 | 4 |

### 8.2 修改文件 (12 个)

| 文件路径 | 改动 | Phase |
|---------|------|-------|
| `lib/constants.dart` | URL改Alpine, 去Node, 改品牌名 | 1 |
| `android/.../BootstrapManager.kt` | 路径改alpine, 去APT/Node/OpenClaw | 1 |
| `android/.../ProcessManager.kt` | 路径改alpine, 去NODE_OPTIONS | 1 |
| `android/.../MainActivity.kt` | 精简方法, 改包名 | 1 |
| `lib/services/bootstrap_service.dart` | Alpine安装流程 | 1 |
| `lib/services/native_bridge.dart` | 精简方法, 删Gateway/Node/SSH | 1 |
| `lib/services/terminal_service.dart` | 路径改alpine | 1 |
| `lib/services/preferences_service.dart` | 增加API key字段 | 3 |
| `lib/models/setup_state.dart` | 简化步骤 | 1 |
| `lib/app.dart` | 路由改造, 品牌改名 | 5 |
| `lib/screens/dashboard_screen.dart` | 改为ChatScreen入口 | 5 |
| `lib/screens/settings_screen.dart` | API key配置UI | 5 |
| `lib/screens/onboarding_screen.dart` | 原生表单 | 5 |
| `pubspec.yaml` | 改名、增减依赖 | 5 |

### 8.3 删除文件 (29 个)

```
# Android Kotlin (4个)
android/.../GatewayService.kt
android/.../NodeForegroundService.kt
android/.../SshForegroundService.kt
android/.../ScreenCaptureService.kt

# Dart Models (5个)
lib/models/ai_provider.dart
lib/models/gateway_state.dart
lib/models/node_frame.dart
lib/models/node_state.dart
lib/models/optional_package.dart

# Dart Providers (3个)
lib/providers/gateway_provider.dart
lib/providers/node_provider.dart
lib/providers/setup_provider.dart

# Dart Services (11个)
lib/services/gateway_service.dart
lib/services/node_service.dart
lib/services/node_ws_service.dart
lib/services/node_identity_service.dart
lib/services/package_service.dart
lib/services/provider_config_service.dart
lib/services/update_service.dart
lib/services/screenshot_service.dart
lib/services/ssh_service.dart
lib/services/capabilities/  (10个文件整个目录)

# Dart Screens (9个)
lib/screens/web_dashboard_screen.dart
lib/screens/node_screen.dart
lib/screens/configure_screen.dart
lib/screens/providers_screen.dart
lib/screens/provider_detail_screen.dart
lib/screens/packages_screen.dart
lib/screens/package_install_screen.dart
lib/screens/logs_screen.dart
lib/screens/ssh_screen.dart

# Dart Widgets (4个)
lib/widgets/gateway_controls.dart
lib/widgets/node_controls.dart
lib/widgets/status_card.dart
lib/widgets/terminal_toolbar.dart

# Assets (1个)
assets/bionic_bypass.js
```

### 8.4 pubspec.yaml 依赖变更

| 依赖 | 操作 | 原因 |
|------|------|------|
| `webview_flutter` | 删除 | 不再需要 WebView dashboard |
| `web_socket_channel` | 删除 | 不再需要 WebSocket (Gateway/Node) |
| `cryptography` | 删除 | 不再需要加密 (Node pairing) |
| `camera` | 删除 | 不再需要摄像头 (Node capability) |
| `geolocator` | 删除 | 不再需要定位 (Node capability) |
| `flutter_blue_plus` | 删除 | 不再需要蓝牙 (Node capability) |
| `usb_serial` | 删除 | 不再需要串口 (Node capability) |

---

## 9. 测试检查清单

### Phase 1: Alpine 环境

- [ ] `flutter build apk --debug` 编译通过, 无编译错误
- [ ] 首次启动显示 Setup Wizard
- [ ] Alpine rootfs 下载成功 (检查 3 种架构)
- [ ] rootfs 解压成功, `isBootstrapComplete()` 返回 true
- [ ] `apk update` 在 proot 中执行成功
- [ ] `apk add bash python3 curl git jq` 安装成功
- [ ] `NativeBridge.runInProot('python3 --version')` 返回版本号
- [ ] `NativeBridge.runInProot('curl --version')` 返回版本号
- [ ] `NativeBridge.runInProot('bash --version')` 返回版本号
- [ ] DNS 解析正常: `NativeBridge.runInProot('ping -c1 google.com')`
- [ ] 二次启动跳过 setup, 直接进入主界面

### Phase 2: Agent Loop

- [ ] LlmService 能成功调用 Anthropic API (非流式)
- [ ] LlmService 能成功调用 Anthropic API (流式)
- [ ] LlmService 能成功调用 OpenAI 兼容 API
- [ ] LlmService 正确处理自定义 baseUrl (代理)
- [ ] AgentService 在无 tool_use 时正常返回文本
- [ ] AgentService 在 tool_use 时正确执行工具并继续循环
- [ ] AgentService 在多次 tool_use 后最终返回文本
- [ ] AgentService.cancel() 能中断正在运行的循环
- [ ] BashTool 能执行 `ls /root` 并返回结果
- [ ] BashTool 处理超时命令 (>120s) 不会挂起
- [ ] BashTool 处理失败命令 (exit code != 0) 返回错误信息
- [ ] ReadFileTool 能读取 `/etc/os-release`
- [ ] ReadFileTool 对不存在的文件返回错误
- [ ] WriteFileTool 能创建新文件
- [ ] WriteFileTool 能覆盖已有文件
- [ ] WebFetchTool 能获取网页内容
- [ ] WebFetchTool HTTP 自动升级为 HTTPS
- [ ] 工具输出超过 50000 字符时被截断

### Phase 3: 数据模型

- [ ] ChatSession 创建/序列化/反序列化正确
- [ ] ChatMessage 支持 TextContent, ToolUseContent, ToolResultContent
- [ ] SessionStorage 保存/加载/删除会话正常
- [ ] ChatProvider 创建新会话后 sessions 列表更新
- [ ] ChatProvider 选择会话后 currentSession 正确
- [ ] ChatProvider 删除会话后列表和 currentSession 更新

### Phase 4: 聊天界面

- [ ] ChatScreen 空状态显示引导文字
- [ ] 输入消息后显示在界面上 (用户气泡)
- [ ] 流式文本实时显示 (光标闪烁)
- [ ] ToolCallCard 默认折叠, 点击展开
- [ ] ToolCallCard 显示执行中旋转动画
- [ ] ToolCallCard 显示成功/失败状态图标
- [ ] AgentStatusBar 显示 "思考中" / "执行工具" / "出错"
- [ ] 取消按钮能停止 Agent 执行
- [ ] 消息列表自动滚动到底部
- [ ] ChatSessionsScreen 显示会话列表
- [ ] 左滑删除会话, 有确认弹窗
- [ ] CodeBlock 复制按钮能复制代码到剪贴板

### Phase 5: 导航 + 设置

- [ ] 首次启动进入 Onboarding (表单式)
- [ ] Onboarding 完成后进入 ChatScreen
- [ ] SettingsScreen API Key 输入/保存/回显正常
- [ ] SettingsScreen Base URL 输入/保存正常
- [ ] SettingsScreen 模型名称输入/保存正常
- [ ] SettingsScreen 系统信息正确显示 (架构, rootfs 状态)
- [ ] 从 ChatScreen 能进入 SettingsScreen
- [ ] 从 ChatScreen 能进入 Terminal (保留)
- [ ] AppBar 标题显示当前会话标题
- [ ] 新建对话按钮创建空会话

### 端到端测试

- [ ] 完整对话流程: 用户输入 -> AI 回复 (无工具)
- [ ] 工具调用流程: 用户要求 "列出文件" -> bash 工具执行 -> AI 解释结果
- [ ] 多轮工具调用: 用户要求 "写一个 Python 脚本然后运行它"
- [ ] 错误恢复: API Key 错误 -> 显示错误消息 -> 修改设置 -> 重试成功
- [ ] 会话持久化: 发送消息 -> 杀掉 App -> 重新打开 -> 会话还在
- [ ] 长文本处理: Agent 输出超长内容时 UI 不卡顿
- [ ] 并发安全: 快速连续点击发送不会重复执行

---

## 附录: 关键设计决策

### 为什么选 Alpine 而不是 Ubuntu?

| 对比 | Ubuntu base | Alpine minirootfs |
|------|------------|-------------------|
| 压缩包大小 | ~50MB | ~3MB |
| 解压后大小 | ~200MB | ~8MB |
| 包管理器 | apt (慢, 复杂) | apk (快, 简单) |
| 初始化时间 | 5-10 分钟 | <1 分钟 |
| Node.js 需求 | 需要单独安装 | 不需要 |
| proot 兼容性 | 需要大量 hack | 原生兼容 |

### 为什么在 Dart 中实现 Agent Loop 而不是用 Node.js?

1. **减少依赖**: 不需要在 proot 中安装 Node.js
2. **启动速度**: 无需等待 Node.js 在 proot 中启动
3. **UI 集成**: Dart Agent 可以直接推送流式事件到 Flutter UI
4. **可控性**: 完全掌控 Agent 行为, 不依赖第三方 OpenClaw 框架
5. **体积**: 去掉 Node.js + npm + OpenClaw 节省约 200MB

### 为什么用 SharedPreferences 而不是 SQLite?

1. **简单**: 无需 SQL schema 迁移
2. **够用**: 预期 <100 个会话, JSON 序列化足够快
3. **依赖少**: SharedPreferences 已在 pubspec 中, 无需新增 sqflite
4. **迁移容易**: 如果后续需要 SQLite, 只需改 SessionStorage 实现
