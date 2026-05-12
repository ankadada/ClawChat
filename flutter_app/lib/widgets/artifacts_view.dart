import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class ArtifactsView extends StatefulWidget {
  final String htmlContent;
  final double height;
  const ArtifactsView({super.key, required this.htmlContent, this.height = 400});

  @override
  State<ArtifactsView> createState() => _ArtifactsViewState();
}

class _ArtifactsViewState extends State<ArtifactsView> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          if (request.url == 'about:blank') return NavigationDecision.navigate;
          return NavigationDecision.prevent;
        },
      ))
      ..loadHtmlString(_sandboxHtml(widget.htmlContent));
  }

  String _sandboxHtml(String html) {
    final csp = '<meta http-equiv="Content-Security-Policy" '
        'content="default-src \'none\'; style-src \'unsafe-inline\'; '
        'script-src \'unsafe-inline\'; img-src data:;">';
    return html.contains('<head')
        ? html.replaceFirst('<head', '<head>$csp<head')
        : '<html><head>$csp</head><body>$html</body></html>';
  }

  @override
  void didUpdateWidget(covariant ArtifactsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.htmlContent != widget.htmlContent) {
      _controller.loadHtmlString(_sandboxHtml(widget.htmlContent));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: WebViewWidget(controller: _controller),
      ),
    );
  }
}
