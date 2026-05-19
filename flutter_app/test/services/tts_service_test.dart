import 'package:clawchat/services/tts_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TtsService speech text preparation', () {
    test('normalizes markdown-heavy assistant text for system TTS', () {
      final service = TtsService();

      final normalized = service.normalizeTextForSpeech('''
# 标题

请查看 [文档](https://example.com/docs)。

```dart
print('hello');
```

| 项目 | 状态 |
| --- | --- |
| API | 正常 |
''');

      expect(normalized, contains('标题'));
      expect(normalized, contains('文档'));
      expect(normalized, contains('代码块'));
      expect(normalized, contains('API'));
      expect(normalized, isNot(contains('https://example.com')));
      expect(normalized, isNot(contains('```')));
      expect(normalized, isNot(contains('|')));
    });

    test('strips symbols that commonly break Android system TTS', () {
      final service = TtsService();

      final normalized = service.normalizeTextForSpeech(
        '系统朗读 ✅ ~~稳定~~ <b>中文</b> #tag @user 123',
      );

      expect(normalized, contains('系统朗读'));
      expect(normalized, contains('稳定'));
      expect(normalized, contains('中文'));
      expect(normalized, contains('123'));
      expect(normalized, isNot(contains('✅')));
      expect(normalized, isNot(contains('@')));
    });

    test('splits long text below the requested system chunk limit', () {
      final service = TtsService();
      final text = List.filled(30, '这是一段用于朗读的中文句子。').join();

      final chunks = service.splitTextForSystemSpeech(text, maxLength: 120);

      expect(chunks.length, greaterThan(1));
      expect(chunks.every((chunk) => chunk.length <= 120), isTrue);
      expect(chunks.join(), text);
    });
  });
}
