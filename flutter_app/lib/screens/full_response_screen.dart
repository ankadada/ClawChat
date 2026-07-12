import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/native_bridge.dart';
import '../widgets/streaming_text.dart';
import '../l10n/app_strings.dart';
import '../layout/foldable_layout.dart';

class FullResponseScreen extends StatefulWidget {
  const FullResponseScreen({
    super.key,
    required this.text,
    this.shareText,
    this.allowShare = true,
  });

  final String text;
  final String? shareText;
  final bool allowShare;

  @override
  State<FullResponseScreen> createState() => _FullResponseScreenState();
}

class _FullResponseScreenState extends State<FullResponseScreen> {
  static const int maxQueryCharacters = 128;
  static const int maxMatches = 200;

  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  List<int> _matches = const [];
  int _matchIndex = 0;

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _search(String rawQuery) {
    final query = rawQuery.characters.take(maxQueryCharacters).toString();
    if (query != rawQuery) {
      _searchController.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
    }
    if (query.isEmpty) {
      setState(() {
        _matches = const [];
        _matchIndex = 0;
      });
      return;
    }
    final matches = <int>[];
    var cursor = 0;
    while (matches.length < maxMatches) {
      final next = widget.text.indexOf(query, cursor);
      if (next < 0) break;
      matches.add(next);
      cursor = next + query.length;
    }
    setState(() {
      _matches = matches;
      _matchIndex = 0;
    });
  }

  void _moveMatch(int delta) {
    if (_matches.isEmpty) return;
    setState(() {
      _matchIndex = (_matchIndex + delta) % _matches.length;
      if (_matchIndex < 0) _matchIndex += _matches.length;
    });
    final fraction =
        widget.text.isEmpty ? 0.0 : _matches[_matchIndex] / widget.text.length;
    final target = _scrollController.position.maxScrollExtent * fraction;
    _scrollController.animateTo(
      target,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final fold = FoldableLayout.resolve(
      media.size,
      media.displayFeatures,
      bottomInset: media.viewInsets.bottom,
    );
    final workspace = _buildWorkspace(context);
    return Scaffold(
      body: Stack(children: [
        Positioned.fromRect(
          rect: fold.primary,
          child: MediaQuery(
            data: fold.hasSeparatedRegions
                ? media.copyWith(
                    size: fold.primary.size,
                    viewInsets: EdgeInsets.zero,
                    displayFeatures: const [],
                  )
                : media,
            child: workspace,
          ),
        ),
      ]),
    );
  }

  Widget _buildWorkspace(BuildContext context) {
    final matchLabel =
        _matches.isEmpty ? '没有匹配' : '${_matchIndex + 1}/${_matches.length}';
    return Scaffold(
      key: const ValueKey('full-response-workspace'),
      appBar: AppBar(
        title: const Text(AppStrings.fullResponse),
        actions: [
          IconButton(
            tooltip: '复制完整回复',
            onPressed: () {
              Clipboard.setData(
                  ClipboardData(text: widget.shareText ?? widget.text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制')),
              );
            },
            icon: const Icon(Icons.copy_outlined),
          ),
          if (widget.allowShare)
            IconButton(
              tooltip: '分享完整回复',
              onPressed: () => NativeBridge.shareText(
                text: widget.shareText ?? widget.text,
                subject: 'ClawChat',
              ),
              icon: const Icon(Icons.share_outlined),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(children: [
              TextField(
                key: const ValueKey('full-response-search'),
                controller: _searchController,
                maxLength: maxQueryCharacters,
                decoration: const InputDecoration(
                  labelText: AppStrings.searchInResponse,
                  prefixIcon: Icon(Icons.search),
                  counterText: '',
                ),
                onChanged: _search,
              ),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                Flexible(
                  child: Semantics(
                    liveRegion: true,
                    label: '搜索结果 $matchLabel',
                    child: Text(matchLabel),
                  ),
                ),
                IconButton(
                  tooltip: '上一个匹配',
                  onPressed: _matches.isEmpty ? null : () => _moveMatch(-1),
                  icon: const Icon(Icons.keyboard_arrow_up),
                ),
                IconButton(
                  tooltip: '下一个匹配',
                  onPressed: _matches.isEmpty ? null : () => _moveMatch(1),
                  icon: const Icon(Icons.keyboard_arrow_down),
                ),
              ]),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            key: const ValueKey('full-response-body'),
            child: FullResponseRenderSurface(
              key: const ValueKey('full-response-render-surface'),
              scrollController: _scrollController,
              text: widget.text,
            ),
          ),
        ]),
      ),
    );
  }
}

@visibleForTesting
class FullResponseRenderSurface extends StatefulWidget {
  const FullResponseRenderSurface({
    super.key,
    required this.scrollController,
    required this.text,
  });

  final ScrollController scrollController;
  final String text;

  @override
  State<FullResponseRenderSurface> createState() =>
      FullResponseRenderSurfaceState();
}

@visibleForTesting
class FullResponseRenderSurfaceState extends State<FullResponseRenderSurface> {
  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: SingleChildScrollView(
        key: const PageStorageKey('full-response-scroll'),
        controller: widget.scrollController,
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: StreamingText(
            text: widget.text,
            renderFullText: true,
          ),
        ),
      ),
    );
  }
}
