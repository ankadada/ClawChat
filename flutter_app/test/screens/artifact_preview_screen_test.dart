import 'package:clawchat/screens/artifact_preview_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isPreviewableHtml', () {
    test('detects full HTML documents', () {
      expect(isPreviewableHtml('<!DOCTYPE html><html></html>'), isTrue);
      expect(isPreviewableHtml('  <html><body>Hello</body></html>'), isTrue);
    });

    test('allows body-only code blocks when language is html', () {
      expect(isPreviewableHtml('<body>Hello</body>', language: 'html'), isTrue);
      expect(isPreviewableHtml('<body>Hello</body>'), isFalse);
    });

    test('rejects non-html content', () {
      expect(isPreviewableHtml('{"html":"<html></html>"}'), isFalse);
      expect(isPreviewableHtml('print("<html></html>")', language: 'python'), isFalse);
    });
  });

  group('sandboxArtifactHtml', () {
    test('injects a CSP that blocks scripts by default', () {
      final html = sandboxArtifactHtml('<html><head></head><body></body></html>',
          allowJavaScript: false);

      expect(html, contains("default-src 'none'"));
      expect(html, contains("script-src 'none'"));
    });

    test('allows only inline scripts after explicit JavaScript enablement', () {
      final html = sandboxArtifactHtml('<p>Hello</p>', allowJavaScript: true);

      expect(html, contains("script-src 'unsafe-inline'"));
      expect(html, contains('<!doctype html>'));
    });
  });
}
