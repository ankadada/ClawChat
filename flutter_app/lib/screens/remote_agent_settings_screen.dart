import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/remote_agent_connector.dart';
import '../providers/chat_provider.dart';
import '../services/remote_agent_configuration_service.dart';

class RemoteAgentSettingsScreen extends StatefulWidget {
  const RemoteAgentSettingsScreen({super.key});

  @override
  State<RemoteAgentSettingsScreen> createState() =>
      _RemoteAgentSettingsScreenState();
}

class _RemoteAgentSettingsScreenState extends State<RemoteAgentSettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _baseUrl = TextEditingController();
  final _agentId = TextEditingController();
  final _credential = TextEditingController();
  bool _disclosureAccepted = false;
  bool _busy = true;
  bool _hasCredential = false;
  bool _canRemoveConfiguration = false;
  bool _requiresMigration = false;
  String? _loadError;
  int _loadGeneration = 0;

  RemoteAgentConfigurationService get _service =>
      context.read<RemoteAgentRuntimeBinding>().configuration ??
      (throw StateError('Remote Agent configuration is unavailable.'));

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    if (mounted) setState(() => _busy = true);
    try {
      await _service.init();
      final config = _service.config;
      final hasCredential = await _service.hasCredential();
      if (!mounted || generation != _loadGeneration) return;
      final supported =
          config?.kind == RemoteAgentConnectorKind.openClawGateway;
      setState(() {
        _requiresMigration = config != null && !supported;
        _baseUrl.text = supported ? config!.baseUrl : '';
        _agentId.text = supported ? config!.remoteAgentId : 'default';
        _hasCredential = supported && hasCredential;
        _canRemoveConfiguration = config != null && hasCredential;
        _loadError = null;
      });
    } on Object {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loadError = '无法读取远程 Agent 设置。输入内容已保留。');
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _agentId.dispose();
    _credential.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await _service.saveConfiguration(
        kind: RemoteAgentConnectorKind.openClawGateway,
        connectorId: 'primary_remote',
        displayName: 'Remote Agent',
        baseUrl: _baseUrl.text,
        remoteAgentId: _agentId.text,
        credential: _credential.text,
      );
      _credential.clear();
      _disclosureAccepted = false;
      _hasCredential = await _service.hasCredential();
      _canRemoveConfiguration = _hasCredential;
      _requiresMigration = false;
      _show('配置已保存。因配置发生变化，请重新阅读并授权。');
    } on Object {
      _show('无法保存远程 Agent 配置，请检查输入。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _grant() async {
    if (!_disclosureAccepted) return;
    setState(() => _busy = true);
    try {
      await _service.grantConsentAndEnable(acceptedAt: DateTime.now());
      _show('远程 Agent 已启用。仍需在每个对话中单独选择使用。');
    } on Object {
      _show('启用失败，请先保存有效配置和凭据。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disable() async {
    setState(() => _busy = true);
    try {
      await _service.disable();
      _disclosureAccepted = false;
      _show('已停用并撤销授权。已选择远程 Agent 的会话将回到本地处理。');
    } on Object {
      _show('无法停用远程 Agent；当前配置未更改，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeCredential() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除凭据与配置？'),
        content: const Text(
          '这会停用远程 Agent，并移除本机保存的凭据和配置。已选择远程 Agent 的会话将不再发送到外部服务。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await _service.removeCredential();
      _baseUrl.clear();
      _agentId.clear();
      _credential.clear();
      _disclosureAccepted = false;
      if (mounted) {
        setState(() {
          _hasCredential = false;
          _canRemoveConfiguration = false;
        });
      }
      _show('凭据和远程配置已移除。');
    } on Object {
      _show('无法移除凭据；现有字段和配置已保留，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final config = _service.config;
    final enabled = _service.isReady &&
        config?.kind == RemoteAgentConnectorKind.openClawGateway;
    return Scaffold(
      appBar: AppBar(title: const Text('远程 Agent 连接器')),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_loadError != null) ...[
                    Semantics(
                      liveRegion: true,
                      child: Card(
                        child: ListTile(
                          leading: const Icon(Icons.error_outline),
                          title: Text(_loadError!),
                          trailing: TextButton(
                            onPressed: _load,
                            child: const Text('重试'),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  const Card(
                    child: ListTile(
                      leading: Icon(Icons.hub_outlined),
                      title: Text('OpenClaw Gateway'),
                      subtitle: Text(
                        '使用官方 /v1/chat/completions 接口；需先在 Gateway 配置中启用 chatCompletions',
                      ),
                    ),
                  ),
                  if (_requiresMigration) ...[
                    const SizedBox(height: 12),
                    const Card(
                      child: ListTile(
                        leading: Icon(Icons.warning_amber_rounded),
                        title: Text('旧版连接器配置已停用'),
                        subtitle: Text(
                          '2.5.0 中误加入的 Coze 配置不会被继续使用。请重新填写 OpenClaw Gateway 地址、Agent ID 和凭据。',
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _baseUrl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Gateway HTTPS 地址',
                      helperText:
                          '例如 https://gateway.example.com；根地址会自动使用 /v1/chat/completions',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      try {
                        canonicalizeRemoteAgentEndpoint(value ?? '');
                        return null;
                      } on Object {
                        return '请输入有效的 HTTPS 地址';
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _agentId,
                    decoration: const InputDecoration(
                      labelText: 'OpenClaw Agent ID',
                      helperText: '默认 Agent 填写 default',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) => (value ?? '').trim().isEmpty
                        ? '请输入 OpenClaw Agent ID'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _credential,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: _hasCredential
                          ? '替换 Gateway Token/密码（留空则保留）'
                          : 'Gateway Token 或密码',
                      border: const OutlineInputBorder(),
                    ),
                    validator: (value) =>
                        !_hasCredential && (value ?? '').trim().isEmpty
                            ? '请输入 Gateway Token 或密码'
                            : null,
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _save,
                    child: const Text('保存配置'),
                  ),
                  const SizedBox(height: 24),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '外部处理披露',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            '启用后，仅当你在某个对话中明确选择远程 Agent 时，当前本地对话文本才会发送到你的 OpenClaw Gateway。Gateway Token/密码等同于该 Gateway 的 operator 凭据，应仅连接可信的 HTTPS 私有入口。远端可能按其配置保留会话；ClawChat 本地不保存 Gateway 会话 ID、原始流帧或请求元数据。',
                          ),
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _disclosureAccepted,
                            onChanged: config?.kind !=
                                    RemoteAgentConnectorKind.openClawGateway
                                ? null
                                : (value) => setState(
                                    () => _disclosureAccepted = value == true),
                            title: const Text('我理解并同意上述外部处理'),
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton(
                                  onPressed: _disclosureAccepted && !enabled
                                      ? _grant
                                      : null,
                                  child: Text(enabled ? '已授权并启用' : '授权并启用'),
                                ),
                              ),
                              if (enabled) ...[
                                const SizedBox(width: 8),
                                OutlinedButton(
                                  onPressed: _disable,
                                  child: const Text('停用'),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_canRemoveConfiguration)
                    TextButton.icon(
                      onPressed: _removeCredential,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('移除凭据与配置'),
                    ),
                ],
              ),
            ),
    );
  }
}
