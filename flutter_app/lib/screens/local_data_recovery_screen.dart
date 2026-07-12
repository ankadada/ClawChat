import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../layout/foldable_layout.dart';
import '../l10n/app_strings.dart';
import '../providers/chat_provider.dart';
import '../services/bounded_file_reader.dart';
import '../services/native_bridge.dart';
import '../services/session_storage.dart';
import '../widgets/foldable_dialog_region.dart';

enum _ExportDestination { save, share, copy }

class LocalDataRecoveryScreen extends StatefulWidget {
  const LocalDataRecoveryScreen({
    super.key,
    this.storage,
    this.restoreSession,
  });

  final SessionStorage? storage;
  final Future<bool> Function(String id)? restoreSession;

  @override
  State<LocalDataRecoveryScreen> createState() =>
      _LocalDataRecoveryScreenState();
}

class _LocalDataRecoveryScreenState extends State<LocalDataRecoveryScreen> {
  late final SessionStorage _storage;
  SessionExportPreview? _exportPreview;
  List<SessionTrashEntry> _trash = const [];
  String? _loadError;
  bool _loading = true;
  bool _busy = false;
  String? _lastImportBackupPath;

  @override
  void initState() {
    super.initState();
    _storage = widget.storage ?? SessionStorage();
    _load();
  }

  Future<void> _load() async {
    if (_loading == false) setState(() => _loading = true);
    try {
      await _storage.init();
      final preview = await _storage.previewExport();
      final trash = await _storage.listTrash();
      if (!mounted) return;
      setState(() {
        _exportPreview = preview;
        _trash = trash;
        _loadError = null;
      });
    } catch (_) {
      if (mounted) setState(() => _loadError = AppStrings.localDataLoadFailed);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final layout = FoldableLayout.resolve(
            Size(constraints.maxWidth, constraints.maxHeight),
            media.displayFeatures,
            bottomInset: media.viewInsets.bottom,
          );
          if (layout.posture == FoldablePosture.book &&
              layout.auxiliary != null) {
            return Stack(
              children: [
                Positioned.fromRect(
                  rect: layout.auxiliary!,
                  child: _buildScopeOverview(),
                ),
                Positioned.fromRect(rect: layout.primary, child: _buildBody()),
              ],
            );
          }
          return Stack(
            children: [
              Positioned.fromRect(rect: layout.primary, child: _buildBody()),
            ],
          );
        },
      ),
    );
  }

  Widget _buildScopeOverview() => const SafeArea(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.shield_outlined, size: 36),
              SizedBox(height: 12),
              Text(
                AppStrings.localDataAuthority,
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              SizedBox(height: 12),
              Text(AppStrings.exportExclusions),
              Spacer(),
              Text(AppStrings.trashRetentionNotice),
            ],
          ),
        ),
      );

  Widget _buildBody() => SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  IconButton(
                    tooltip:
                        MaterialLocalizations.of(context).backButtonTooltip,
                    onPressed: () => Navigator.maybePop(context),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const Expanded(
                    child: Text(
                      AppStrings.localDataRecovery,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _loadError != null
                      ? _errorState(_loadError!, _load)
                      : ListView(
                          key: const Key('local-data-scroll'),
                          padding: const EdgeInsets.all(16),
                          children: [
                            _buildExportCard(),
                            const SizedBox(height: 16),
                            _buildImportCard(),
                            const SizedBox(height: 16),
                            _buildTrashCard(),
                          ],
                        ),
            ),
            if (!_loading && _loadError == null)
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: _busy ? null : _pickAndPreviewImport,
                        icon: const Icon(Icons.preview_outlined),
                        label: const Text(AppStrings.chooseImportFile),
                      ),
                      FilledButton.icon(
                        key: const Key('local-data-primary-action'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: _busy || _exportPreview!.sessionCount == 0
                            ? null
                            : () => _export(_ExportDestination.save),
                        icon: const Icon(Icons.save_alt),
                        label: const Text(AppStrings.saveFile),
                      ),
                    ],
                  ),
                ),
              ),
            if (_busy) const LinearProgressIndicator(minHeight: 3),
          ],
        ),
      );

  Widget _errorState(String message, VoidCallback retry) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: retry,
                child: const Text(AppStrings.retry),
              ),
            ],
          ),
        ),
      );

  Widget _buildExportCard() {
    final preview = _exportPreview!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              AppStrings.exportConversations,
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(AppStrings.exportScopeSummary(
              preview.sessionCount,
              preview.earliest,
              preview.latest,
              preview.estimatedBytes,
            )),
            const SizedBox(height: 8),
            const Text(AppStrings.exportInclusions),
            const Text(AppStrings.exportExclusions),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _destinationButton(
                  Icons.save_alt,
                  AppStrings.saveFile,
                  _ExportDestination.save,
                ),
                _destinationButton(
                  Icons.share_outlined,
                  AppStrings.androidShare,
                  _ExportDestination.share,
                ),
                _destinationButton(
                  Icons.copy_outlined,
                  AppStrings.copy,
                  _ExportDestination.copy,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _destinationButton(
    IconData icon,
    String label,
    _ExportDestination destination,
  ) =>
      FilledButton.tonalIcon(
        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: _busy || _exportPreview!.sessionCount == 0
            ? null
            : () => _export(destination),
        icon: Icon(icon),
        label: Text(label),
      );

  Future<void> _export(_ExportDestination destination) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final artifact = await _storage.exportAllAsJson();
      switch (destination) {
        case _ExportDestination.copy:
          await Clipboard.setData(ClipboardData(text: artifact));
        case _ExportDestination.share:
          final opened = await NativeBridge.shareText(
            text: artifact,
            subject: AppStrings.localDataExportSubject,
          );
          if (!opened) throw StateError('share unavailable');
        case _ExportDestination.save:
          final path = await FilePicker.platform.saveFile(
            dialogTitle: AppStrings.saveConversationExport,
            fileName: 'clawchat-sessions-v2.json',
            type: FileType.custom,
            allowedExtensions: const ['json'],
          );
          if (path == null) return;
          final temp = File('$path.tmp');
          await temp.writeAsString(artifact, flush: true);
          await temp.rename(path);
      }
      _show(AppStrings.exportDestinationComplete);
    } catch (_) {
      _show(AppStrings.exportDestinationFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _buildImportCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                AppStrings.importConversations,
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(AppStrings.importDryRunNotice),
              const SizedBox(height: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(48, 48),
                ),
                onPressed: _busy ? null : _pickAndPreviewImport,
                icon: const Icon(Icons.preview_outlined),
                label: const Text(AppStrings.chooseImportFile),
              ),
              if (_lastImportBackupPath != null) ...[
                const SizedBox(height: 8),
                Text(AppStrings.preImportBackupAvailable(
                  File(_lastImportBackupPath!).uri.pathSegments.last,
                )),
                TextButton.icon(
                  onPressed: _busy ? null : _rollbackLastImport,
                  icon: const Icon(Icons.restore),
                  label: const Text(AppStrings.rollbackImport),
                ),
              ],
            ],
          ),
        ),
      );

  Future<void> _pickAndPreviewImport() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final bytes = await BoundedFileReader.readBytes(
        path,
        validateBytes: (length) {
          if (length <= 0 || length > SessionStorage.maxTransferBytes) {
            throw const FormatException('Import file size is invalid.');
          }
        },
      );
      final source = const Utf8Decoder(allowMalformed: false).convert(bytes);
      final preview = await _storage.previewImport(source);
      if (!mounted) return;
      final policy = await _showImportPreview(preview);
      if (policy == null) return;
      final result = await _storage.applyImport(preview, policy);
      _lastImportBackupPath = result.backupPath;
      _show(AppStrings.importResult(
        result.imported,
        result.skipped,
        result.replaced,
      ));
      await _load();
    } catch (_) {
      _show(AppStrings.importFailedSafe);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<SessionImportConflictPolicy?> _showImportPreview(
    SessionImportPreview preview,
  ) async {
    var policy = SessionImportConflictPolicy.keepExisting;
    return showDialog<SessionImportConflictPolicy>(
      context: context,
      builder: (dialogContext) => FoldableDialogRegion(
        child: StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text(AppStrings.importPreview),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(AppStrings.importPreviewSummaryValues(
                    schema: preview.schemaVersion,
                    valid: preview.validCount,
                    invalid: preview.invalidCount,
                    duplicates: preview.duplicateCount,
                    conflicts: preview.conflictCount,
                    fresh: preview.newCount,
                    requiredBytes: preview.requiredBytes,
                  )),
                  const SizedBox(height: 8),
                  const Text(AppStrings.importSensitiveExclusions),
                  for (final value in SessionImportConflictPolicy.values)
                    RadioListTile<SessionImportConflictPolicy>(
                      value: value,
                      groupValue: policy,
                      onChanged: preview.canApply
                          ? (selected) =>
                              setDialogState(() => policy = selected!)
                          : null,
                      title: Text(_policyLabel(value)),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text(AppStrings.cancel),
              ),
              FilledButton(
                onPressed: preview.canApply
                    ? () => Navigator.pop(dialogContext, policy)
                    : null,
                child: const Text(AppStrings.importButton),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _policyLabel(SessionImportConflictPolicy value) => switch (value) {
        SessionImportConflictPolicy.keepExisting =>
          AppStrings.importKeepExisting,
        SessionImportConflictPolicy.importAsCopy => AppStrings.importAsCopy,
        SessionImportConflictPolicy.replace => AppStrings.importReplace,
      };

  Future<void> _rollbackLastImport() async {
    final path = _lastImportBackupPath;
    if (path == null || _busy) return;
    setState(() => _busy = true);
    try {
      final count = await _storage.rollbackImportBackup(path);
      _show(AppStrings.rollbackImportComplete(count));
      await _load();
    } catch (_) {
      _show(AppStrings.rollbackImportFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _buildTrashCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                AppStrings.sessionTrash,
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              const Text(AppStrings.trashRetentionNotice),
              if (_trash.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(AppStrings.trashEmpty),
                )
              else
                for (final entry in _trash)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(entry.title, maxLines: 1),
                    subtitle: Text(AppStrings.trashExpires(entry.expiresAt)),
                    trailing: Wrap(
                      children: [
                        IconButton(
                          tooltip: AppStrings.restore,
                          onPressed: _busy ? null : () => _restore(entry),
                          icon: const Icon(Icons.restore),
                        ),
                        IconButton(
                          tooltip: AppStrings.deletePermanently,
                          onPressed: _busy ? null : () => _permanent(entry),
                          icon: const Icon(Icons.delete_forever_outlined),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        ),
      );

  Future<void> _restore(SessionTrashEntry entry) async {
    final restore = widget.restoreSession ??
        (String id) => context.read<ChatProvider>().restoreDeletedSession(id);
    setState(() => _busy = true);
    try {
      final restored = await restore(entry.sessionId);
      _show(restored ? AppStrings.sessionRestored : AppStrings.restoreFailed);
      await _load();
    } catch (_) {
      _show(AppStrings.restoreFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _permanent(SessionTrashEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => FoldableDialogRegion(
          child: AlertDialog(
        title: const Text(AppStrings.deletePermanently),
        content: const Text(AppStrings.deletePermanentlyConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(AppStrings.delete),
          ),
        ],
      )),
    );
    if (confirmed != true) return;
    await _storage.permanentlyDeleteTrash(entry.sessionId);
    await _load();
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
