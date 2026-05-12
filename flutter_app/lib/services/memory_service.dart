import 'dart:convert';
import 'native_bridge.dart';

/// Cross-session memory service.
///
/// Stores user-provided facts/preferences that should be remembered across
/// all conversations.
///
/// Integration: In ChatProvider.sendMessage(), append MemoryService.buildMemoryPrompt()
/// to the system prompt before sending to the LLM.
class MemoryService {
  static const _memoryPath = 'root/.clawchat_memory.json';
  static List<String> _cachedMemories = [];
  static bool _loaded = false;

  static Future<List<String>> getMemories() async {
    if (!_loaded) {
      try {
        final content = await NativeBridge.readRootfsFile(_memoryPath);
        if (content != null && content.isNotEmpty) {
          _cachedMemories = List<String>.from(jsonDecode(content));
        }
      } catch (_) {}
      _loaded = true;
    }
    return List.unmodifiable(_cachedMemories);
  }

  static Future<void> addMemory(String fact) async {
    await getMemories();
    if (!_cachedMemories.contains(fact)) {
      _cachedMemories.add(fact);
      await _save();
    }
  }

  static Future<void> removeMemory(int index) async {
    if (index >= 0 && index < _cachedMemories.length) {
      _cachedMemories.removeAt(index);
      await _save();
    }
  }

  static Future<void> _save() async {
    await NativeBridge.writeRootfsFile(_memoryPath, jsonEncode(_cachedMemories));
  }

  static String buildMemoryPrompt() {
    if (_cachedMemories.isEmpty) return '';
    final memoryList = _cachedMemories.map((m) => '- $m').join('\n');
    return '\n\nUser memories (facts the user asked you to remember):\n$memoryList';
  }
}
