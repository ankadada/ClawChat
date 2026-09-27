import 'package:clawchat/screens/chat_screen.dart';
import 'package:clawchat/widgets/tool_call_card.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('chat reading width', () {
    test('phone width keeps the previous rule', () {
      expect(
        chatReadingWidthFor(windowWidth: 390, availableWidth: 390),
        closeTo(390 * 0.86, 0.001),
      );
      expect(
        chatReadingWidthFor(windowWidth: 640, availableWidth: 1000),
        closeTo(640, 0.001),
      );
    });

    test('wide chat pane caps at 860 and never exceeds the pane', () {
      expect(
        chatReadingWidthFor(windowWidth: 1200, availableWidth: 1000),
        closeTo(860, 0.001),
      );
      expect(
        chatReadingWidthFor(windowWidth: 900, availableWidth: 500),
        closeTo(468, 0.001),
      );
      expect(
        chatReadingWidthFor(windowWidth: 700, availableWidth: 700),
        closeTo(668, 0.001),
      );
    });
  });

  group('plain-text copy', () {
    test('strips headings, emphasis, list markers and code fences', () {
      const markdown = '# Title\n\n**bold** and *italic* and `code`\n\n- one\n'
          '- two\n\n```dart\nfinal x = 1;\n```\n';
      final plain = stripMarkdownMarkers(markdown);
      expect(plain, contains('Title'));
      expect(plain, contains('bold and italic and code'));
      expect(plain, contains('one'));
      expect(plain, contains('final x = 1;'));
      expect(plain, isNot(contains('**')));
      expect(plain, isNot(contains('`')));
      expect(plain, isNot(contains('# Title')));
      expect(plain, isNot(contains('- one')));
    });

    test('keeps link labels and targets, keeps image alt text', () {
      const markdown = 'see [docs](https://example.com/a) and '
          '![chart](https://example.com/c.png)';
      final plain = stripMarkdownMarkers(markdown);
      expect(plain, contains('docs (https://example.com/a)'));
      expect(plain, contains('chart'));
      expect(plain, isNot(contains('](')));
    });

    test('leaves ordinary prose untouched', () {
      const prose = 'The value is 42.\nSecond line.';
      expect(stripMarkdownMarkers(prose), prose);
    });
  });

  group('tool result images', () {
    test('finds a data URL, an image URL and a workspace path', () {
      const output = 'wrote screenshot\n'
          'data:image/png;base64,iVBORw0KGgo=\n'
          'also https://example.com/render.png?size=2\n'
          'saved at /root/workspace/out/chart.webp done\n';
      final images = extractToolResultImages(output);
      expect(
        images.map((image) => image.kind),
        [
          ToolResultImageKind.data,
          ToolResultImageKind.network,
          ToolResultImageKind.path,
        ],
      );
      expect(images[2].value, '/root/workspace/out/chart.webp');
    });

    test('deduplicates and ignores non-image references', () {
      const output = 'https://example.com/a.png https://example.com/a.png\n'
          'https://example.com/a.txt\n'
          'notes.txt\n';
      final images = extractToolResultImages(output);
      expect(images, hasLength(1));
      expect(images.single.kind, ToolResultImageKind.network);
    });

    test('an empty or null output has no images', () {
      expect(extractToolResultImages(null), isEmpty);
      expect(extractToolResultImages('   '), isEmpty);
    });
  });
}
