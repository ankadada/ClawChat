import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../l10n/app_strings.dart';
import '../services/native_bridge.dart';

class ArtifactPreviewScreen extends StatefulWidget {
  final String htmlContent;
  final String title;

  const ArtifactPreviewScreen({
    super.key,
    required this.htmlContent,
    this.title = AppStrings.preview,
  });

  @override
  State<ArtifactPreviewScreen> createState() => _ArtifactPreviewScreenState();
}

class _ArtifactPreviewScreenState extends State<ArtifactPreviewScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;
  bool _javaScriptEnabled = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..enableZoom(true)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          if (mounted) setState(() => _isLoading = true);
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _isLoading = false);
        },
        onWebResourceError: (_) {
          if (mounted) setState(() => _isLoading = false);
        },
        onNavigationRequest: (request) {
          if (request.url.startsWith('about:blank')) {
            return NavigationDecision.navigate;
          }
          return NavigationDecision.prevent;
        },
      ));
    _loadHtml();
  }

  @override
  void didUpdateWidget(covariant ArtifactPreviewScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.htmlContent != widget.htmlContent) {
      _loadHtml();
    }
  }

  Future<void> _loadHtml() async {
    if (mounted) setState(() => _isLoading = true);
    await _controller.loadHtmlString(
      sandboxArtifactHtml(
        widget.htmlContent,
        allowJavaScript: _javaScriptEnabled,
      ),
    );
  }

  Future<void> _setJavaScriptEnabled(bool enabled) async {
    if (enabled && !_javaScriptEnabled) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text(AppStrings.enableJavaScript),
          content: const Text(AppStrings.enableJavaScriptWarning),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text(AppStrings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(AppStrings.confirm),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    setState(() => _javaScriptEnabled = enabled);
    await _controller.setJavaScriptMode(
      enabled ? JavaScriptMode.unrestricted : JavaScriptMode.disabled,
    );
    await _loadHtml();
  }

  Future<void> _copyHtml() async {
    await Clipboard.setData(ClipboardData(text: widget.htmlContent));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(AppStrings.copied),
        duration: Duration(seconds: 1),
      ),
    );
  }

  Future<void> _openInBrowser() async {
    try {
      final directory = await getTemporaryDirectory();
      final file = File(
        '${directory.path}/clawchat_artifact_${DateTime.now().millisecondsSinceEpoch}.html',
      );
      await file.writeAsString(widget.htmlContent);
      final opened = await NativeBridge.openHtmlFile(file.path);
      if (!opened) throw Exception(AppStrings.openInBrowserFailed);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${AppStrings.openInBrowserFailed}: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        leading: IconButton(
          tooltip: AppStrings.close,
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            tooltip: AppStrings.reloadPreview,
            icon: const Icon(Icons.refresh),
            onPressed: _loadHtml,
          ),
          IconButton(
            tooltip: _javaScriptEnabled
                ? AppStrings.disableJavaScript
                : AppStrings.enableJavaScript,
            icon: Icon(_javaScriptEnabled ? Icons.code : Icons.code_off),
            onPressed: () => _setJavaScriptEnabled(!_javaScriptEnabled),
          ),
          IconButton(
            tooltip: AppStrings.openInBrowser,
            icon: const Icon(Icons.open_in_browser),
            onPressed: _openInBrowser,
          ),
          IconButton(
            tooltip: AppStrings.copyHtml,
            icon: const Icon(Icons.copy),
            onPressed: _copyHtml,
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(
              color: theme.colorScheme.surface,
              child: WebViewWidget(controller: _controller),
            ),
          ),
          if (_isLoading)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x33000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}

bool isPreviewableHtml(String content, {String? language}) {
  final lower = content.trimLeft().toLowerCase();
  final isFullHtmlDocument =
      lower.startsWith('<!doctype') || lower.startsWith('<html');
  final isHtmlLanguage = language?.trim().toLowerCase() == 'html';

  if (isFullHtmlDocument) return true;
  if (!isHtmlLanguage) return false;
  return lower.contains('<!doctype') ||
      lower.contains('<html') ||
      lower.contains('<body');
}

@visibleForTesting
String sandboxArtifactHtml(String html, {required bool allowJavaScript}) {
  final scriptSrc = allowJavaScript ? "'unsafe-inline'" : "'none'";
  final csp = '<meta http-equiv="Content-Security-Policy" '
      'content="default-src \'none\'; style-src \'unsafe-inline\'; '
      'script-src $scriptSrc; img-src data: blob:;">';
  final headPattern = RegExp(r'<head[\s>]', caseSensitive: false);
  if (headPattern.hasMatch(html)) {
    return html.replaceFirstMapped(
      RegExp(r'<head[^>]*>', caseSensitive: false),
      (match) => '${match.group(0)}$csp',
    );
  }
  return '<!doctype html><html><head>$csp</head><body>$html</body></html>';
}
