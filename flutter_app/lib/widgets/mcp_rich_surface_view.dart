import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/mcp_rich_surface.dart';
import '../services/mcp_rich_surface_protocol.dart';

const _bridgeChannelName = 'clawchatMcpRichBridge';

/// Fixed local document for the optional MCP App-style surface.
///
/// It has no interpolation point for model/tool content. The only dynamic data
/// arrives in a host-generated `render` message and is inserted with
/// `textContent`, never `innerHTML`. Its CSP denies all network connections,
/// frames, forms, navigation targets, and external resources.
@visibleForTesting
const String mcpRichSurfaceHtml = r'''<!doctype html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; connect-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; frame-src 'none'; form-action 'none'; base-uri 'none';">
<style>
  :root { color-scheme: light dark; font-family: sans-serif; }
  body { margin: 0; padding: 12px; color: CanvasText; background: Canvas; }
  h1 { margin: 0 0 8px; font-size: 1.1rem; }
  p { margin: 0 0 12px; line-height: 1.45; white-space: pre-wrap; }
  dl { margin: 0 0 12px; display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 6px 12px; }
  dt { font-weight: 600; }
  dd { margin: 0; overflow-wrap: anywhere; }
  .actions { display: flex; flex-wrap: wrap; gap: 8px; }
  button { min-height: 48px; min-width: 48px; padding: 8px 12px; font: inherit; }
</style>
</head><body>
<main id="root" aria-live="polite"></main>
<script>
(() => {
  'use strict';
  const origin = 'clawchat_mcp_rich_local_v1';
  const channel = 'clawchatMcpRichBridge';
  const root = document.getElementById('root');
  let surfaceId = '';
  let requestCounter = 0;

  const send = (type, fields) => {
    const bridge = window[channel];
    if (!bridge || typeof bridge.postMessage !== 'function' || !surfaceId) return;
    const message = Object.assign({schemaVersion: 1, origin, type, surfaceId}, fields || {});
    bridge.postMessage(JSON.stringify(message));
  };

  const appendText = (parent, tag, text) => {
    const node = document.createElement(tag);
    node.textContent = String(text);
    parent.appendChild(node);
    return node;
  };

  const reportSize = () => {
    const height = Math.max(80, Math.min(720, Math.round(document.documentElement.scrollHeight)));
    send('resize', {height});
  };

  const render = (view) => {
    root.replaceChildren();
    appendText(root, 'h1', view.title);
    appendText(root, 'p', view.summary);
    if (Array.isArray(view.metrics) && view.metrics.length) {
      const list = document.createElement('dl');
      for (const metric of view.metrics) {
        appendText(list, 'dt', metric.label);
        appendText(list, 'dd', metric.value);
      }
      root.appendChild(list);
    }
    if (Array.isArray(view.actions) && view.actions.length) {
      const actions = document.createElement('div');
      actions.className = 'actions';
      for (const action of view.actions) {
        const button = document.createElement('button');
        button.type = 'button';
        button.textContent = String(action.label);
        button.addEventListener('click', () => {
          requestCounter += 1;
          send('request_action', {
            requestId: `request-${requestCounter}`,
            actionId: String(action.actionId),
          });
        });
        actions.appendChild(button);
      }
      root.appendChild(actions);
    }
    reportSize();
  };

  window.addEventListener('mcp-host-message', (event) => {
    const message = event.detail;
    if (!message || message.schemaVersion !== 1 || message.origin !== origin ||
        message.type !== 'render' || typeof message.surfaceId !== 'string' ||
        message.renderer !== 'host_status_v1' || !message.view) return;
    surfaceId = message.surfaceId;
    render(message.view);
  });

  if (typeof ResizeObserver === 'function') {
    new ResizeObserver(reportSize).observe(document.documentElement);
  }
  window.addEventListener('beforeunload', () => send('close'));
})();
</script>
</body></html>''';

/// An opt-in isolated rich surface. It is never selected by normal chat text;
/// callers must provide an app-owned [McpRichSurface].
class McpRichSurfaceView extends StatefulWidget {
  const McpRichSurfaceView({
    super.key,
    required this.surface,
    this.actionRouter,
    this.onClosed,
    this.initialHeight = 240,
    @visibleForTesting this.forceUnavailable = false,
    @visibleForTesting this.childForTesting,
  });

  final McpRichSurface surface;
  final McpRichSurfaceActionRouter? actionRouter;
  final VoidCallback? onClosed;
  final double initialHeight;

  /// Allows deterministic widget assertions without instantiating a platform
  /// WebView. It is ignored by production callers.
  @visibleForTesting
  final bool forceUnavailable;

  @visibleForTesting
  final Widget? childForTesting;

  @override
  State<McpRichSurfaceView> createState() => _McpRichSurfaceViewState();
}

/// Native opt-in control for the optional local renderer. The authoritative
/// [StructuredResultCard] remains a sibling in ChatScreen even while this view
/// is expanded or unavailable.
class McpRichSurfaceDisclosure extends StatefulWidget {
  const McpRichSurfaceDisclosure({
    super.key,
    required this.surface,
    required this.actionRouter,
    @visibleForTesting this.forceUnavailable = false,
    @visibleForTesting this.richChildForTesting,
  });

  final McpRichSurface surface;
  final McpRichSurfaceActionRouter actionRouter;

  @visibleForTesting
  final bool forceUnavailable;

  @visibleForTesting
  final Widget? richChildForTesting;

  @override
  State<McpRichSurfaceDisclosure> createState() =>
      _McpRichSurfaceDisclosureState();
}

class _McpRichSurfaceDisclosureState extends State<McpRichSurfaceDisclosure> {
  bool _expanded = false;

  void _toggleExpanded() {
    setState(() => _expanded = !_expanded);
  }

  String? _lastGeometryKey;

  String _geometryKey(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final insets = MediaQuery.viewInsetsOf(context);
    final features = MediaQuery.of(context)
        .displayFeatures
        .map((feature) =>
            '${feature.bounds.left},${feature.bounds.top},${feature.bounds.width},${feature.bounds.height}:${feature.type.name}:${feature.state.name}')
        .join(';');
    return '${size.width}x${size.height}|${insets.left},${insets.top},${insets.right},${insets.bottom}|$features';
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final geometryKey = _geometryKey(context);
    if (_expanded &&
        _lastGeometryKey != null &&
        _lastGeometryKey != geometryKey) {
      _expanded = false;
    }
    _lastGeometryKey = geometryKey;
  }

  @override
  void didUpdateWidget(covariant McpRichSurfaceDisclosure oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.surface.surfaceId != widget.surface.surfaceId ||
        oldWidget.surface.operationId != widget.surface.operationId) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 4),
        Semantics(
          button: true,
          expanded: _expanded,
          label:
              _expanded ? 'Hide optional rich view' : 'Show optional rich view',
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              key: const Key('mcp-rich-surface-toggle'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                alignment: Alignment.centerLeft,
              ),
              onPressed: _toggleExpanded,
              child: Row(
                children: [
                  Icon(_expanded
                      ? Icons.expand_less_outlined
                      : Icons.web_asset_outlined),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _expanded ? 'Hide rich view' : 'Show rich view',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: _boundedRichHeight(context),
            child: McpRichSurfaceView(
              surface: widget.surface,
              actionRouter: widget.actionRouter,
              forceUnavailable: widget.forceUnavailable,
              childForTesting: widget.richChildForTesting,
              onClosed: () {
                if (mounted) setState(() => _expanded = false);
              },
            ),
          ),
        ],
      ],
    );
  }

  double _boundedRichHeight(BuildContext context) {
    final available = MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom;
    if (available <= 600) return 96;
    return (available * 0.46).clamp(120.0, 320.0).toDouble();
  }
}

class _McpRichSurfaceViewState extends State<McpRichSurfaceView> {
  WebViewController? _controller;
  late McpRichSurfaceBridge _bridge;
  double? _requestedHeight;
  bool _ready = false;
  bool _unavailable = false;

  @override
  void initState() {
    super.initState();
    _bridge = McpRichSurfaceBridge(
      surface: widget.surface,
      actionRouter: widget.actionRouter,
    );
    _requestedHeight = widget.initialHeight;
    if (widget.forceUnavailable) {
      _unavailable = true;
    } else if (widget.childForTesting == null) {
      unawaited(_configureAndLoad());
    }
  }

  @override
  void didUpdateWidget(covariant McpRichSurfaceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.surface != widget.surface ||
        oldWidget.actionRouter != widget.actionRouter) {
      _bridge = McpRichSurfaceBridge(
        surface: widget.surface,
        actionRouter: widget.actionRouter,
      );
      _requestedHeight = widget.initialHeight;
      unawaited(_sendRender());
    }
  }

  Future<void> _configureAndLoad() async {
    try {
      final controller = WebViewController();
      _controller = controller;
      // JavaScript is needed only for the fixed document above. No model or
      // tool-supplied HTML is loaded into this controller.
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) =>
            mcpRichSurfaceAllowsNavigation(request.url)
                ? NavigationDecision.navigate
                : NavigationDecision.prevent,
        onWebResourceError: (_) => _markUnavailable(),
        onPageFinished: (_) => unawaited(_sendRender()),
      ));
      await controller.addJavaScriptChannel(
        _bridgeChannelName,
        onMessageReceived: (message) => unawaited(_handleBridgeMessage(
          message.message,
        )),
      );
      await controller.loadHtmlString(mcpRichSurfaceHtml,
          baseUrl: 'about:blank');
      if (!mounted) return;
      setState(() => _ready = true);
      await _sendRender();
    } on Object {
      _markUnavailable();
    }
  }

  Future<void> _sendRender() async {
    final controller = _controller;
    if (!_ready || _unavailable || controller == null) return;
    final message = jsonEncode(widget.surface.renderMessage);
    try {
      await controller.runJavaScript(
        "window.dispatchEvent(new CustomEvent('mcp-host-message', {detail: $message}));",
      );
    } on Object {
      _markUnavailable();
    }
  }

  Future<void> _handleBridgeMessage(String rawMessage) async {
    final outcome = await _bridge.handleMessage(rawMessage);
    if (!mounted) return;
    switch (outcome.kind) {
      case McpRichSurfaceBridgeOutcomeKind.resized:
        setState(() => _requestedHeight = outcome.height);
      case McpRichSurfaceBridgeOutcomeKind.closed:
        widget.onClosed?.call();
      case McpRichSurfaceBridgeOutcomeKind.rejected:
        // A malformed or stale bridge message is a local rich-surface failure.
        // Do not render its contents or continue a potentially desynchronized
        // WebView session.
        _markUnavailable();
      case McpRichSurfaceBridgeOutcomeKind.actionForwarded:
        break;
    }
  }

  void _markUnavailable() {
    if (!mounted || _unavailable) return;
    setState(() => _unavailable = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_unavailable) {
      return McpRichSurfaceUnavailableNotice(title: widget.surface.view.title);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = MediaQuery.sizeOf(context).height -
            MediaQuery.viewInsetsOf(context).bottom;
        final boundedViewport = constraints.maxHeight.isFinite
            ? math.min(viewport, constraints.maxHeight)
            : viewport;
        final height = mcpRichSurfaceHeight(
          requestedHeight: _requestedHeight ?? widget.initialHeight,
          availableHeight: boundedViewport,
          textScaler: MediaQuery.textScalerOf(context),
        );
        final child = widget.childForTesting ??
            (_controller == null
                ? const Center(child: CircularProgressIndicator())
                : WebViewWidget(controller: _controller!));
        return Semantics(
          container: true,
          label: 'Optional rich app surface: ${widget.surface.view.title}. '
              'Actions require native confirmation.',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SizedBox(
                  height: height, width: double.infinity, child: child),
            ),
          ),
        );
      },
    );
  }
}

/// Native fallback for invalid protocol traffic and unavailable WebView hosts.
/// It exposes no rich-surface action and leaves the normal native result UI
/// untouched.
class McpRichSurfaceUnavailableNotice extends StatelessWidget {
  const McpRichSurfaceUnavailableNotice({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        label: 'Rich content unavailable. Native result remains available.',
        child: Card.outlined(
          child: ListTile(
            leading: const Icon(Icons.web_asset_off_outlined),
            title: Text(title),
            subtitle: const Text(
              'Rich content could not be displayed safely. Native content remains available.',
            ),
          ),
        ),
      );
}

/// WebView navigation is closed: the fixed local document can load only its
/// initial `about:blank` document. `open_link` protocol messages are also
/// rejected by the bridge while no explicit future network capability exists.
@visibleForTesting
bool mcpRichSurfaceAllowsNavigation(String url) => url == 'about:blank';

/// Chooses a height that stays within the current viewport (including IME) and
/// increases its minimum at 200% text scale. Width remains fluid so it fits a
/// 320dp narrow/foldable pane without a horizontal overflow contract.
@visibleForTesting
double mcpRichSurfaceHeight({
  required double requestedHeight,
  required double availableHeight,
  required TextScaler textScaler,
}) {
  final viewport =
      availableHeight.isFinite ? math.max(0.0, availableHeight) : 560.0;
  final scale = textScaler.scale(1.0).clamp(1.0, 2.0);
  final preferredMinimum = 160.0 * scale;
  final maximum = math.min(560.0, viewport);
  final minimum = math.min(preferredMinimum, maximum);
  return requestedHeight.clamp(minimum, maximum).toDouble();
}
