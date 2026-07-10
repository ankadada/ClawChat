/// Centralized UI strings for ClawChat.
///
/// ClawChat is Chinese-first while keeping established English technical
/// labels such as API, Terminal, Anthropic, and OpenAI. The app intentionally
/// uses this static table for now instead of Flutter's generated i18n stack.
/// Future localization can replace this file with locale-aware lookups.
class AppStrings {
  AppStrings._();

  // ── General ──────────────────────────────────────────────────────
  static const appName = 'ClawChat';
  static const cancel = '取消';
  static const confirm = '确定';
  static const delete = '删除';
  static const copy = '复制';
  static const copyText = '复制文本';
  static const copyMarkdown = '复制为 Markdown';
  static const copied = '已复制';
  static const share = '分享';
  static const shareFailed = '分享失败';
  static const sharedContentReady = '分享内容已放入新对话，请确认后发送';
  static const forkConversation = '从这里分支';
  static const forkCreated = '已创建分支对话';
  static const forkFailed = '创建分支失败';
  static String forkedFromTitle(String title) => '分支自: $title';
  static const save = '保存';
  static const saved = '已保存';
  static const done = '完成';
  static const loading = '加载中...';
  static const error = '错误';
  static const retry = '重试';
  static const more = '更多';
  static const refresh = '刷新';
  static const close = '关闭';
  static const open = 'Open';
  static const renderError = '渲染错误';
  static const searchSources = '搜索来源';
  static const yes = '是';
  static const no = '否';
  static const unknown = '未知';
  static const password = '密码';
  static const passwordRequired = '请输入密码';
  static const passwordMismatch = '两次输入的密码不一致';

  // ── Chat screen ──────────────────────────────────────────────────
  static const newChat = '新对话';
  static const selectModelGroup = '选择模型组';
  static const defaultModelGroup = '默认模型配置';
  static const defaultModelGroupSubtitle = '使用当前启用的 Provider Profile';
  static String modelGroupFallbackCount(int count) =>
      count == 0 ? '无备用模型' : '$count 个备用模型';
  static const settings = '设置';
  static const switchModel = '切换模型';
  static const editSystemPrompt = '编辑系统提示词';
  static const resetDefault = '恢复默认';
  static const useGlobalDefault = '使用全局默认';
  static const leaveEmptyForDefault = '留空则使用全局设置中的模型';
  static const sendMessageToStart = '发送消息开始对话';
  static const aiAssistantCapabilities = 'AI 助手可以执行命令、读写文件、访问网页';
  static const emptyPromptSummarizeCode = '总结一下这段代码';
  static const emptyPromptWriteEmail = '帮我写一封邮件';
  static const emptyPromptTranslateText = '翻译这段文字';
  static const emptyPromptExplainConcept = '解释这个概念';
  static String currentModelLabel(String modelName) => '当前模型  $modelName';
  static const userLabel = '你';
  static const aiLabel = 'AI';
  static const aiProcessing = 'AI 正在处理...';
  static const queueInputHint = '输入消息加入队列...';
  static String messageQueueFullHint(int current, int max) =>
      '队列已满 ($current/$max)';
  static String messageQueueFull(int max) => '消息队列已满（最多 $max 条）';
  static String messagesQueued(int count) => '$count 条消息排队中';
  static const sendQueued = '发送';
  static const clearMessageQueue = '清空队列';
  static const messageQueueCleared = '队列已清空';
  static const clearQueueBeforeRegenerate = '请先清空消息队列再重新生成';
  static String contextCompactedNotice(
    int droppedMessageCount,
    int estimatedTokens,
  ) =>
      '对话上下文已压缩（移除 $droppedMessageCount 条旧消息，保留约 $estimatedTokens tokens）';
  static String contextToolCallsCleanedNotice(
    int droppedBlockCount,
    int estimatedTokens,
  ) =>
      '对话上下文已压缩（清理了 $droppedBlockCount 个不完整的工具调用，保留约 $estimatedTokens tokens）';
  static const contextSummaryGenerating = '正在整理上下文...';
  static String contextSummaryCompactedNotice(int count) =>
      '对话上下文已压缩为摘要（覆盖 $count 条旧消息）';
  static const contextSummaryFailed = '上下文摘要生成失败，已使用截断上下文继续';
  static const contextSummary = '上下文摘要';
  static const contextSummaryNone = '当前对话还没有上下文摘要';
  static const contextSummaryPreview = '摘要预览';
  static const contextSummaryClear = '清除摘要';
  static const contextSummaryClearConfirm = '清除当前摘要？历史消息不会被删除。';
  static const contextSummaryManualCompactBefore = '压缩此处之前';
  static const contextSummaryNoSession = '当前没有可处理的对话';
  static const contextSummarySelectLaterMessage = '请选择更靠后的消息';
  static const contextSummaryNoSafePrefix = '所选位置之前没有完整、安全的上下文边界';
  static const contextSummaryBusy = '当前会话正在回复或整理上下文，请稍后再试';
  static String contextSummaryRebuilt(int count) => '已重建上下文摘要（覆盖 $count 条消息）';
  static String contextSummaryRebuildFailed(String error) => '重建摘要失败: $error';
  static String contextSummaryCoverage(int count, int tokens) =>
      '覆盖 $count 条 API 消息，来源约 $tokens tokens';
  static const encryptedContentRecoveryNotice = '检测到缓存上下文失效，已自动恢复对话上下文';
  static const encryptedContentRecoveryFailed = '自动恢复上下文失败，请重新发送消息';
  static String loadOlderMessages(int count) => '加载更早 $count 条消息';
  static String hiddenOlderMessages(int count) => '还有 $count 条更早消息';
  static const inputHint = '输入消息...';
  static const toolApprovalTitle = '工具执行确认';
  static const toolApprovalArguments = '参数';
  static const toolApprovalDeny = '拒绝';
  static const toolApprovalAllowOnce = '允许一次';
  static const toolApprovalAllowSession = '本会话允许';
  static const toolApprovalAllowAuto = '自动允许';
  static const riskLow = '低风险';
  static const riskMedium = '中风险';
  static const riskHigh = '高风险';
  static String imageAttachmentLabel(String label) => '图片附件 $label';
  static const modelFetchPresetNotice =
      'Failed to fetch models, showing presets';
  static String modelFetchFailed(String e) => 'Failed to fetch models: $e';

  // ── Chat sessions screen ─────────────────────────────────────────
  static const chatHistory = '对话记录';
  static const noChats = '暂无对话';
  static const deleteChat = '删除对话';
  static String deleteChatConfirm(String title) => '确定删除 "$title" ?';
  static String deleteEnvVarConfirm(String name) => '确定删除环境变量 $name？';
  static const deleteMemoryTitle = '删除记忆';
  static const deleteMemoryConfirm = '确定删除此记忆？';
  static const justNow = '刚刚';
  static const today = '今天';
  static const yesterday = '昨天';
  static const past7Days = '过去7天';
  static const earlier = '更早';
  static String minutesAgo(int n) => '$n 分钟前';
  static String hoursAgo(int n) => '$n 小时前';
  static String compactDaysAgo(int n) => '$n天前';
  static String daysAgo(int n) => '$n 天前';

  // ── Dashboard screen ─────────────────────────────────────────────
  static const dashboard = '首页';
  static const chat = '聊天';
  static const chatSubtitle = '与 AI 助手对话';
  static const terminal = '终端';
  static const terminalSubtitle = '打开 Alpine Linux 终端';
  static const configureApiKey = '配置 API Key';
  static const configureApiKeySubtitle = '设置 AI 模型和 API 密钥';
  static const settingsSubtitle = '系统配置和信息';
  static const dashboardConnected = '连接已配置';
  static const dashboardWaitingApi = '等待配置 API';

  // ── Onboarding screen ────────────────────────────────────────────
  static const welcomeTitle = '欢迎使用 ClawChat';
  static const selectApiFormat = '选择 API 格式';
  static const anthropicSubtitle = '直接使用 Anthropic API';
  static const openaiCompatible = 'OpenAI 兼容';
  static const openaiCompatibleSubtitle = '支持 OpenAI, DeepSeek, OpenRouter 等';
  static const enterApiKey = '输入 API Key';
  static const baseUrlDefaultHint = 'Base URL (留空使用默认)';
  static const modelName = '模型名称';
  static const stepComplete = '完成';
  static const allReadyMessage = '一切就绪! 点击完成开始使用 ClawChat。';
  static const pleaseEnterApiKey = '请输入 API Key';
  static const fetchingModels = '正在获取模型列表...';
  static const fetchModelsFailed = '获取失败，请手动输入';
  static const manualInput = '手动输入...';
  static const selectModel = '选择模型';
  static const fetchModelsButton = '获取模型列表';
  static const apiKeyHelper = '用于连接所选 API 服务';
  static const baseUrlHelper = '留空时使用默认地址';
  static const testConnection = '测试连接';
  static const manualModelHint = '也可以直接手动输入模型名称';
  static String modelsFetched(int count) => '已获取 $count 个模型';
  static const previousStep = '上一步';
  static const nextStep = '下一步';

  // ── Settings screen ──────────────────────────────────────────────
  static const apiConfig = 'API 配置';
  static const apiFormat = 'API 格式';
  static const baseUrlOptional = 'Base URL (可选)';
  static const model = '模型';
  static const providerProfiles = 'Provider Profiles';
  static const addProviderProfile = '新增配置';
  static const modelGroups = 'Model Groups';
  static const newProviderProfile = '新配置';
  static const providerProfileDetails = '配置详情';
  static const providerProfileName = '配置名称';
  static const editProviderProfile = '编辑配置';
  static const apiKeyRequiredToUse = '使用此配置前需要填写 API Key';
  static String profileNeedsApiKey(String name) =>
      '请先为 "$name" 填写 API Key，再切换到此配置。';
  static const cannotDeleteLastProfile = '至少保留一个配置';
  static const deleteProviderProfileTitle = '删除配置?';
  static String deleteProviderProfileConfirm(String name) =>
      '确定删除 "$name" 吗？此操作会移除保存的 API Key。';
  static const deleteActiveProfileTitle = '删除当前配置?';
  static String deleteActiveProfileConfirm(String name) =>
      '删除 "$name" 后将自动切换到其他配置。';
  static String providerProfileSaveFailed(String e) => '配置保存失败: $e';
  static const modelFallback = '模型回退';
  static const modelFallbackEnabled = '自动回退';
  static const modelFallbackDisabled = '未启用回退目标';
  static const modelFallbackSubtitle = '请求失败时按顺序尝试你配置的其他模型';
  static const modelFallbackPrivacyNotice = '回退会把本次对话发送到所选配置的服务端点，请只选择你信任的配置。';
  static const addFallbackTarget = '添加回退目标';
  static const editFallbackTarget = '编辑回退目标';
  static const fallbackTargetProfile = '目标配置';
  static const fallbackModelSelection = '回退模型';
  static const fallbackUseTargetDefault = '使用目标配置默认模型';
  static const fallbackCustomModel = '自定义模型...';
  static const fallbackCustomModelLabel = '自定义模型';
  static const fallbackModelOverride = '模型覆盖（可选）';
  static const fallbackUsesTargetModel = '使用目标配置模型';
  static const fallbackModelSelectHelper = '留空使用目标配置模型，也可选择已知模型';
  static const fallbackNoModelCatalog = '未获取到模型列表，可手动输入自定义模型';
  static const noFallbackProfilesAvailable = '请先创建第二个模型配置';
  static const removeFallbackTarget = '移除回退目标';
  static const moveFallbackTargetUp = '上移回退目标';
  static const moveFallbackTargetDown = '下移回退目标';
  static String modelFallbackUsedNotice({
    required String primary,
    required String fallback,
    required String reason,
  }) =>
      '主模型 $primary 请求失败（$reason），已改用 $fallback。';
  static const advancedModelSettings = '高级模型设置';
  static const saveSettings = '保存设置';
  static const settingsSaved = '设置已保存';
  static String loadSettingsFailed(String e) => '加载设置失败: $e';
  static const systemInfo = '系统信息';
  static const architecture = '架构';
  static const rootfs = 'Rootfs';
  static const installed = '已安装';
  static const notInstalled = '未安装';
  static const maintenance = '维护';
  static const reinitialize = '重新初始化';
  static const reinstallAlpine = '重新安装 Alpine 环境';
  static const reinitializeConfirmTitle = '重新初始化环境？';
  static const reinitializeConfirmMessage =
      '将重新进入初始化流程，可能会覆盖现有 Alpine 环境。确定继续吗？';
  static const about = '关于';
  static const settingsAppearance = '外观';
  static const settingsVoice = '语音';
  static const settingsModelApi = '模型/API';
  static const settingsAgentSkills = 'Agent/技能';
  static const settingsData = '数据';
  static const toolApprovalPolicy = '工具审批策略';
  static const toolApprovalPolicyAlways = '每次询问';
  static const toolApprovalPolicySessionFirst = '会话首次询问';
  static const toolApprovalPolicyAuto = '自动允许';
  static const toolApprovalPolicyAutoWarning = '所有工具将自动执行，包括命令行和文件操作';
  static String toolAutoApprovedNotification(String name) =>
      'ClawChat 已自动允许 $name 执行';
  static String maxConcurrentAgents(int count) => '最大并发任务数: $count';
  static String maxConcurrentAgentsReached(int count) => '已达最大并发数（$count 个任务）';

  // ── Setup wizard screen ──────────────────────────────────────────
  static const initClawChat = '初始化 ClawChat';
  static const initializingMessage = '正在初始化环境，可能需要几分钟。';
  static const downloadMessage = '将下载 Alpine Linux 到设备上，约 3MB。';
  static const startingInit = '开始初始化...';
  static const unknownError = '未知错误';
  static const startSetup = '开始初始化';
  static const downloadRootfs = '下载 Alpine rootfs';
  static const extractRootfs = '解压根文件系统';
  static const installPackages = '安装软件包';
  static const initComplete = '初始化完成!';
  static const currentOperation = '当前操作';

  // ── Splash screen ────────────────────────────────────────────────
  static const tagline = 'AI Agent for Android';
  static const splashLoading = 'Loading...';
  static const checkingSetupStatus = 'Checking setup status...';

  // ── Terminal screen ──────────────────────────────────────────────
  static const terminalTitle = 'Terminal';
  static const screenshot = 'Screenshot';
  static const openUrl = 'Open URL';
  static const paste = 'Paste';
  static const restart = 'Restart';
  static const terminalFontSize = '终端字号';
  static const terminalFontAuto = '自动字号';
  static const startingTerminal = 'Starting terminal...';
  static const screenshotUnavailable = '截图功能暂不可用';
  static const copiedToClipboard = 'Copied to clipboard';
  static const linkCopied = 'Link copied';
  static const noUrlFound = 'No URL found in selection';
  static const openLink = 'Open Link';

  // ── Tool call card ───────────────────────────────────────────────
  static const readFile = '读取文件';
  static const writeFile = '写入文件';
  static const webRequest = '网页请求';
  static const inputLabel = 'Input';
  static const outputLabel = 'Output';

  // ── Agent status bar ──────────────────────────────────────────────
  static const statusThinking = '思考中...';
  static const statusStreaming = '生成回复...';
  static const statusTooling = '执行工具...';
  static const statusError = '出错';
  static const statusProcessing = '处理中...';
  static String toolExecuting(String name) => '执行工具: $name';

  // ── Code block / Artifacts ────────────────────────────────────────
  // (copy/copied already defined in General)
  static const preview = '预览';
  static const artifactsPreview = '网页预览';
  static const reloadPreview = '重新加载预览';
  static const openInBrowser = '在浏览器打开';
  static const openInBrowserFailed = '打开浏览器失败';
  static const copyHtml = '复制 HTML';
  static const enableJavaScript = '启用 JavaScript';
  static const disableJavaScript = '禁用 JavaScript';
  static const enableJavaScriptWarning = '启用 JavaScript 可能存在安全风险，确定要开启吗？';

  // ── Thinking intensity ────────────────────────────────────────────
  static const thinkingIntensity = '思考强度';
  static const thinkingOff = '关闭';
  static const thinkingLow = '低';
  static const thinkingMedium = '中';
  static const thinkingHigh = '高';
  static const thinkingMax = '最大';
  static const reasoningPanelTitle = '思考过程';
  static const reasoningPanelStreaming = '正在接收思考过程';
  static const reasoningPanelCollapsed = '已折叠思考过程';
  static const reasoningPanelExpand = '展开';
  static const reasoningPanelCollapse = '收起';
  static const reasoningPanelShowingRecent = '仅显示最近内容，完整内容已保存在消息中';
  static String reasoningPanelCharacters(int count) => '$count 字符';

  // ── Advanced LLM config ────────────────────────────────────────────
  static const contextLength = '上下文长度';
  static const contextTokenBudget = '上下文 Token 预算';
  static const autoCompact = '自动压缩';
  static const autoCompactSubtitle = '超出上下文 Token 预算时自动截断旧消息';
  static const temperature = '温度';
  static const temperatureLow = '精确';
  static const temperatureHigh = '创意';
  static const chars50k = '50K 字符';
  static const chars100k = '100K 字符 (默认)';
  static const chars200k = '200K 字符';
  static const tokens4k = '4K tokens';
  static const tokens32k = '32K tokens';
  static const tokens64k = '64K tokens (默认)';
  static const tokens200k = '200K tokens';

  // ── Skills ────────────────────────────────────────────────────────
  static const skills = '技能';
  static const noSkillsFound =
      '未发现技能。将 SKILL.md 放入 /root/workspace/skills/ 目录。';
  static const skillsLoaded = '已加载技能';
  static const importSkill = '导入技能';
  static const importLocalSkill = '导入本地技能';
  static const localFilePath = '文件路径';
  static const skillUrl = '技能仓库地址';
  static const importButton = '导入';
  static const importFailed = '导入失败';
  static const installPresets = '安装预设技能';
  static const archiveSkill = 'Archive (.zip, .tar.gz, .tgz)';
  static const directory = 'Directory';
  static const selectSkillArchive =
      'Select a .zip, .tar.gz, or .tgz skill archive';

  // ── Environment Variables ─────────────────────────────────────────
  static const envVars = '环境变量';
  static const addEnvVar = '添加环境变量';
  static const envVarName = '变量名';
  static const envVarValue = '变量值';
  static const envVarNameRequired = 'Error: 环境变量名必填';
  static const envVarInvalidName = 'Error: 环境变量名只能包含字母、数字和下划线，且不能以数字开头';
  static const envVarInvalidAction = 'Error: action 必须是 set 或 delete';
  static String envVarProtectedName(String name) =>
      'Error: $name 是系统保留环境变量，不能通过工具修改';
  static String envVarSet(String name) => '已设置环境变量 $name';
  static String envVarDeleted(String name) => '已删除环境变量 $name';

  // ── Theme ──────────────────────────────────────────────────────────
  static const theme = '主题';
  static const themeSystem = '跟随系统';
  static const themeLight = '浅色';
  static const themeDark = '深色';

  // ── Font size ──────────────────────────────────────────────────────
  static const fontSize = '字体大小';

  // ── Notifications ─────────────────────────────────────────────────
  static const notifyOnComplete = '完成通知';
  static const notifyOnCompleteSubtitle = 'AI 回复完成后发送通知（后台时）';
  static const privacyMode = '隐私模式';
  static const privacyModeSubtitle =
      '开启后，shell 输出中检测到的环境变量值在送达模型前会被打码（例如 sk-1********ajhks）。'
      '少于 8 个字符的值会被全部替换为 *。聊天中用户可见的输出保持不变。';

  // ── Phone integration ─────────────────────────────────────────────
  static const phoneIntegration = '手机集成';
  static const phoneIntegrationDesc =
      'AI 可以通过 phone_intent 工具操作系统：设闹钟、加日历、打开网页、分享等。'
      '日历/联系人首次使用时会弹运行时权限。下面两项默认关闭，开启后 AI 才能直接打电话或发短信。';
  static const allowCall = '允许直接拨打电话';
  static const allowCallSubtitle = '关闭时 AI 只能跳到拨号面板等你确认';
  static const allowSms = '允许直接发送短信';
  static const allowSmsSubtitle = '高风险：开启后 AI 可以直接发送短信，谨慎使用';

  // ── Export ─────────────────────────────────────────────────────────
  static const exportChat = '导出对话';
  static const exportedToClipboard = '对话已复制到剪贴板';
  static const shareSheetOpened = '已打开系统分享';

  // ── Search ─────────────────────────────────────────────────────────
  static const searchConversations = '搜索标题或消息内容...';
  static const searching = '搜索中...';
  static const searchCurrentConversation = '搜索当前对话';
  static const searchMessagesHint = '输入关键词搜索本会话消息';
  static const noSearchResults = '没有匹配消息';
  static String searchResultCount(int count) => '$count 条匹配';
  static String searchResultPosition(int index) => '第 ${index + 1} 条消息';

  // ── Attach ─────────────────────────────────────────────────────────
  static const attachFile = '添加附件';
  static const scrollToBottom = '回到底部';
  static const pickImage = '选择图片';
  static const pickFile = '选择文件';
  static const attachFailed = '附件上传失败';
  static const removeAttachment = '移除附件';

  // ── Usage ─────────────────────────────────────────────────────────
  static const usageSummary = '用量统计';
  static const sessionUsageSummary = '本会话用量';
  static const globalUsageSummary = '全局用量统计';
  static const usageSummarySubtitle = '基于已保存消息的 token 用量';
  static const usageMessages = '有用量记录的消息';
  static const usageInputTokens = '输入 tokens';
  static const usageOutputTokens = '输出 tokens';
  static const usageTotalTokens = '合计 tokens';
  static const usageCacheTokens = '缓存 tokens';
  static const usageUnavailable = '未保存';
  static const usageCost = '费用';
  static const usageCostUnavailable = '未配置价格，未计算';

  // ── Regenerate ─────────────────────────────────────────────────────
  static const regenerate = '重新生成';
  static const assistantErrorTitle = '回复失败';
  static const assistantErrorRetryUnavailable = '这次失败不适合直接重试';
  static const assistantRetryStarted = '已重新发送';
  static const assistantRetryUnavailable = '当前失败状态无法重试';
  static const assistantRetryBusy = '当前会话正在处理，请稍后再试';
  static const assistantRetryMissingApiKey = '请先配置 API Key 后再重试';
  static const assistantRetryFailed = '重试失败';

  // ── Voice ──────────────────────────────────────────────────────────
  static const voiceUnavailable = '语音识别不可用';
  static const transcribing = '正在识别语音...';
  static const transcribeFailed = '语音识别失败，请重试';
  static const voiceRecognition = '语音能力';
  static const voiceRecognitionDesc = '没有系统语音引擎的设备（如部分国产手机），通过 API 实现语音输入和朗读。'
      '填写代理支持的模型名称，留空则使用系统引擎。';
  static const whisperModelLabel = '语音识别模型（STT）';
  static const ttsModelLabel = '语音合成模型（TTS）';
  static const whisperModelRequired = '请在设置 → 语音能力中填写语音识别模型名称（如 whisper-1）';
  static const audioPermissionDenied = '请授予录音权限后重试';
  static const testSystemVoice = '测试系统语音';
  static const voiceDiagnosticRunning = '正在测试系统语音...';
  static const voiceDiagnosticTitle = '系统语音诊断';
  static const voiceDiagnosticTtsHeader = 'TTS 系统朗读';
  static const voiceDiagnosticSttHeader = 'STT 系统识别';

  // ── Message actions ────────────────────────────────────────────────
  static const quoteReply = '引用回复';

  // ── Environment Variables (additional) ─────────────────────────────
  static const noEnvVars = '暂无环境变量';
  static const envVarsAgentRunningNotice = '修改将在下次启动 Agent 时生效';

  // ── Preset skills ──────────────────────────────────────────────────
  static String presetSkillsInstalled(int count) => '已安装 $count 个预设技能';
  static const installFailed = '安装失败';

  // ── Quick prompts ──────────────────────────────────────────────────
  static const promptTranslate = '翻译这段';
  static const promptTranslateTemplate = '请翻译以下内容：\n';
  static const promptSummarize = '总结一下';
  static const promptSummarizeTemplate = '请总结：\n';
  static const promptExplainCode = '解释代码';
  static const promptExplainCodeTemplate = '请解释这段代码：\n';
  static const promptWriteEmail = '写邮件';
  static const promptWriteEmailTemplate = '请帮我写一封邮件：\n';
  static const promptPolish = '修改润色';
  static const promptPolishTemplate = '请帮我修改润色以下文字：\n';
  static const promptBrainstorm = '头脑风暴';
  static const promptBrainstormTemplate = '请帮我头脑风暴：\n';

  // ── Message edit ───────────────────────────────────────────────────
  static const editMessage = '编辑消息';
  static const editAndResend = '编辑并重新发送';
  static const editMessageHint = '修改消息内容...';
  static const editMessageEmpty = '消息内容不能为空';
  static const editMessageInvalid = '只能编辑带文本的用户消息';
  static const editMessageBlockedActive = '当前会话正在回复或有排队消息，暂不能编辑重发';
  static const editMessageMissingApiKey = '请先配置 API Key 再编辑重发';
  static const editMessageBranchStarted = '已创建分支并重新发送';
  static const editMessageBranchFailed = '编辑重发失败';
  static const deleteMessage = '删除消息';

  // ── Prompt profiles ────────────────────────────────────────────────
  static const promptProfiles = '提示词配置';
  static const promptProfilesEmpty = '暂无提示词配置';
  static const promptProfileName = '名称';
  static const promptProfilePrompt = '系统提示词';
  static const promptProfileAdd = '新增配置';
  static const promptProfileEdit = '编辑配置';
  static const promptProfileApplyGlobal = '设为全局提示词';
  static const promptProfileApplySession = '应用到当前会话';
  static const promptProfileAppliedGlobal = '已设为全局提示词';
  static const promptProfileAppliedSession = '已应用到当前会话';
  static const promptProfileDeleteConfirm = '删除这个提示词配置？';
  static const promptProfileInvalid = '名称和系统提示词不能为空';

  // ── Session management ──────────────────────────────────────────
  static const renameSession = '重命名会话';
  static const sessionTitle = '会话标题';
  static const clearAllSessions = '清空所有会话';
  static const clearAllConfirm = '确定要删除所有会话吗？此操作不可恢复。';

  // ── About ─────────────────────────────────────────────────────────
  static const aboutDescription =
      'ClawChat 是一个运行在 Android 上的 AI 助手，内置 Alpine Linux 环境，支持工具调用和技能扩展。';
  static const license = '开源协议';

  // ── Network ───────────────────────────────────────────────────────
  static const networkError = '网络连接失败，请检查网络后重试';

  // ── Chat provider ────────────────────────────────────────────────
  static const apiKeyNotConfigured = '请先在设置中配置 API Key';

  // ── TTS ──────────────────────────────────────────────────────────
  static const ttsPlay = '朗读';
  static const ttsStop = '停止朗读';
  static const ttsPause = '暂停朗读';
  static const ttsResume = '继续朗读';
  static const ttsSystemEngine = '系统引擎';
  static String ttsApiEngine(String model) => 'API: $model';

  // ── Per-session system prompt ────────────────────────────────────
  static const systemPromptTitle = '系统提示词';
  static const systemPromptHint = '自定义此会话的系统提示词...';

  // ── Data management (export/import) ───────────────────────────────
  static const dataManagement = '数据管理';
  static const exportAll = '导出全部对话';
  static const importConversations = '导入对话';
  static const exportSuccess = '已导出到剪贴板';
  static String importSuccess(int count) => '成功导入 $count 个对话';
  static const exportConfig = '导出配置';
  static const exportConfigSubtitle = '备份 API 密钥、环境变量、应用设置';
  static const importConfig = '导入配置';
  static const importConfigSubtitle = '从备份文件恢复配置';
  static const encryptSecrets = '加密敏感信息';
  static const encryptSecretsSubtitle = '使用密码加密 API 密钥和环境变量';
  static const setPassword = '设置密码';
  static const confirmPassword = '确认密码';
  static const exportConfigWithoutEncryption = '不加密导出？';
  static const exportConfigPlainWarning =
      '导出文件将包含你的 API 密钥和环境变量明文，请妥善保管。确定不加密？';
  static const exportConfigRedactedByDefault = '未加密导出默认会脱敏；只有确认后才导出明文密钥。';
  static const exportConfigPlaintextSecrets = '导出明文密钥';
  static const exportConfigPlaintextSecretsSubtitle =
      '关闭时，未加密导出会打码 API 密钥、环境变量和 MCP 凭据';
  static const configExported = '配置已导出';
  static const exportConfigFailed = '导出配置失败';
  static const importConfigPreview = '导入预览';
  static const configVersion = '版本';
  static const configExportedAt = '导出时间';
  static const configEncrypted = '已加密';
  static const encryptedPreviewHidden = '加密文件，导入后可查看';
  static const conflictResolution = '冲突处理';
  static const conflictMerge = '合并（新增不覆盖）';
  static const conflictReplace = '覆盖（全部替换）';
  static const conflictSkip = '跳过已有';
  static const importConfigComplete = '配置导入完成';
  static String configImportSummary(
    int profiles,
    int envVars,
    int skipped, {
    int mcpServers = 0,
    int mcpSkipped = 0,
  }) =>
      '导入了 $profiles 个配置文件，$envVars 个环境变量，$mcpServers 个 MCP 服务器，跳过 ${skipped + mcpSkipped} 个已有配置。';
  static const invalidConfigFile = '无效的配置文件格式';
  static const importConfigFailed = '导入配置失败';
  // importFailed is already defined in the Skills section above

  // ── Tool safety ──────────────────────────────────────────────────
  static const toolSafety = '工具安全';
  static const toolAlwaysDeny = '始终拒绝工具';
  static const toolAlwaysDenySubtitle = '被拒绝的工具不会进入确认弹窗，也不会执行';
  static const bashDenyPatterns = 'Bash 命令拒绝规则';
  static const bashDenyPatternsSubtitle = '命中规则的 bash 命令会在执行前被拦截';
  static const addBashDenyPattern = '添加 Bash 拒绝规则';
  static const bashDenyPatternHint = '输入正则或文本片段';
  static const noBashDenyPatterns = '暂无 Bash 拒绝规则';
  static const anthropicPromptCache = 'Anthropic Prompt Cache';
  static const anthropicPromptCacheSubtitle = '官方 Anthropic API 默认启用，其他提供方不生效';

  // ── MCP ──────────────────────────────────────────────────────────
  static const mcpServers = 'MCP 服务器';
  static const mcpServersSubtitle = '配置本地 stdio MCP 工具服务器，工具执行仍会经过审批';
  static const mcpStdioUnsupportedAndroid =
      '当前 Android 版本暂不启动 stdio MCP 服务器；配置会保留，但不会执行 npx/proot 服务器。';
  static const noMcpServers = '暂无 MCP 服务器';
  static const addMcpServer = '添加 MCP 服务器';
  static const editMcpServer = '编辑 MCP 服务器';
  static const mcpServerName = '显示名称';
  static const mcpCommand = '命令';
  static const mcpArgs = '参数（每行一个）';
  static const mcpEnv = '环境变量（KEY=value，每行一个）';
  static const mcpEnabled = '启用';
  static const mcpInvalid = '名称和命令不能为空';
  static const mcpEnvKeysHidden = '环境变量值已隐藏；保留占位符将继续使用原值';
  static String deleteMcpServerConfirm(String name) => '删除 MCP 服务器 "$name"？';

  // ── Folder / grouping ─────────────────────────────────────────────
  static const allConversations = '全部对话';
  static const moveToFolder = '移动到文件夹';
  static const newFolder = '新建文件夹';
  static const folderName = '文件夹名称';
  static const noFolder = '无分组';

  // ── Memory ────────────────────────────────────────────────────────
  static const memoryManagement = '记忆管理';
  static const memoryEnabled = '启用记忆';
  static const memoryEnabledSubtitle = '关闭后不会注入记忆，也不会暴露记忆工具';
  static const sessionMemory = '本会话记忆';
  static const sessionMemoryFollowGlobal = '跟随全局';
  static const sessionMemoryOn = '开启';
  static const sessionMemoryOff = '关闭';
  static const addMemory = '添加记忆';
  static const memoryHint = '输入要记住的信息...';
  static const noMemories = '暂无记忆';
  static const memoryDesc = 'AI 会在所有对话中记住这些信息';

  // ── Alternatives / regenerate branches ────────────────────────────
  static String alternativeOf(int current, int total) => '$current/$total';

  // ── Multi-model compare ──────────────────────────────────────────
  static const compareMode = '多模型对比';
  static const selectModels = '选择对比模型';
  static const comparing = '正在对比...';
  static const compareStart = '开始对比';
  static const noModelsSelected = '请至少选择两个模型';
}
