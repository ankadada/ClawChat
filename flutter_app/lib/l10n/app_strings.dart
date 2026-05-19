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

  // ── Chat screen ──────────────────────────────────────────────────
  static const newChat = '新对话';
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
  static String contextCompactedNotice(int retainedCount) =>
      '对话上下文已压缩（保留最近 $retainedCount 条消息）';
  static const inputHint = '输入消息...';
  static const toolApprovalTitle = '工具执行确认';
  static const toolApprovalArguments = '参数';
  static const toolApprovalDeny = '拒绝';
  static const toolApprovalAllowOnce = '允许一次';
  static const toolApprovalAllowSession = '本会话允许';
  static const riskLow = '低风险';
  static const riskMedium = '中风险';
  static const riskHigh = '高风险';
  static String imageAttachmentLabel(String label) => '图片附件 $label';
  static const modelFetchPresetNotice = 'Failed to fetch models, showing presets';
  static String modelFetchFailed(String e) => 'Failed to fetch models: $e';

  // ── Chat sessions screen ─────────────────────────────────────────
  static const chatHistory = '对话记录';
  static const noChats = '暂无对话';
  static const deleteChat = '删除对话';
  static String deleteChatConfirm(String title) => '确定删除 "$title" ?';
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
  static const about = '关于';
  static const settingsAppearance = '外观';
  static const settingsVoice = '语音';
  static const settingsModelApi = '模型/API';
  static const settingsAgentSkills = 'Agent/技能';
  static const settingsData = '数据';

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

  // ── Advanced LLM config ────────────────────────────────────────────
  static const contextLength = '上下文长度';
  static const autoCompact = '自动压缩';
  static const autoCompactSubtitle = '超出上下文长度时自动截断旧消息';
  static const temperature = '温度';
  static const temperatureLow = '精确';
  static const temperatureHigh = '创意';
  static const chars50k = '50K 字符';
  static const chars100k = '100K 字符 (默认)';
  static const chars200k = '200K 字符';

  // ── Skills ────────────────────────────────────────────────────────
  static const skills = '技能';
  static const noSkillsFound = '未发现技能。将 SKILL.md 放入 /root/workspace/skills/ 目录。';
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
  static const selectSkillArchive = 'Select a .zip, .tar.gz, or .tgz skill archive';

  // ── Environment Variables ─────────────────────────────────────────
  static const envVars = '环境变量';
  static const addEnvVar = '添加环境变量';
  static const envVarName = '变量名';
  static const envVarValue = '变量值';

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

  // ── Phone integration ─────────────────────────────────────────────
  static const phoneIntegration = '手机集成';
  static const phoneIntegrationDesc =
      'AI 可以通过 phone_intent 工具操作系统：设闹钟、加日历、打开网页、分享等。'
      '日历/联系人首次使用时会弹运行时权限。下面两项默认关闭，开启后 AI 才能直接打电话或发短信。';
  static const allowCall = '允许直接拨打电话';
  static const allowCallSubtitle = '关闭时 AI 只能跳到拨号面板等你确认';
  static const allowSms = '允许直接发送短信';
  static const allowSmsSubtitle = '高风险：AI 可读银行/登录验证码或乱发短信，谨慎开启';

  // ── Export ─────────────────────────────────────────────────────────
  static const exportChat = '导出对话';
  static const exportedToClipboard = '对话已复制到剪贴板';
  static const shareSheetOpened = '已打开系统分享';

  // ── Search ─────────────────────────────────────────────────────────
  static const searchConversations = '搜索标题或消息内容...';
  static const searching = '搜索中...';

  // ── Attach ─────────────────────────────────────────────────────────
  static const attachFile = '添加附件';
  static const scrollToBottom = '回到底部';
  static const pickImage = '选择图片';
  static const pickFile = '选择文件';
  static const attachFailed = '附件上传失败';
  static const removeAttachment = '移除附件';

  // ── Regenerate ─────────────────────────────────────────────────────
  static const regenerate = '重新生成';

  // ── Voice ──────────────────────────────────────────────────────────
  static const voiceUnavailable = '语音识别不可用';
  static const transcribing = '正在识别语音...';
  static const transcribeFailed = '语音识别失败，请重试';
  static const voiceRecognition = '语音能力';
  static const voiceRecognitionDesc =
      '没有系统语音引擎的设备（如部分国产手机），通过 API 实现语音输入和朗读。'
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
  static const deleteMessage = '删除消息';

  // ── Session management ──────────────────────────────────────────
  static const renameSession = '重命名会话';
  static const sessionTitle = '会话标题';
  static const clearAllSessions = '清空所有会话';
  static const clearAllConfirm = '确定要删除所有会话吗？此操作不可恢复。';

  // ── About ─────────────────────────────────────────────────────────
  static const aboutDescription = 'ClawChat 是一个运行在 Android 上的 AI 助手，内置 Alpine Linux 环境，支持工具调用和技能扩展。';
  static const license = '开源协议';

  // ── Network ───────────────────────────────────────────────────────
  static const networkError = '网络连接失败，请检查网络后重试';

  // ── Chat provider ────────────────────────────────────────────────
  static const apiKeyNotConfigured = '请先在设置中配置 API Key';

  // ── TTS ──────────────────────────────────────────────────────────
  static const ttsPlay = '朗读';
  static const ttsStop = '停止朗读';

  // ── Per-session system prompt ────────────────────────────────────
  static const systemPromptTitle = '系统提示词';
  static const systemPromptHint = '自定义此会话的系统提示词...';

  // ── Data management (export/import) ───────────────────────────────
  static const dataManagement = '数据管理';
  static const exportAll = '导出全部对话';
  static const importConversations = '导入对话';
  static const exportSuccess = '已导出到剪贴板';
  static String importSuccess(int count) => '成功导入 $count 个对话';
  // importFailed is already defined in the Skills section above

  // ── Folder / grouping ─────────────────────────────────────────────
  static const allConversations = '全部对话';
  static const moveToFolder = '移动到文件夹';
  static const newFolder = '新建文件夹';
  static const folderName = '文件夹名称';
  static const noFolder = '无分组';

  // ── Memory ────────────────────────────────────────────────────────
  static const memoryManagement = '记忆管理';
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
