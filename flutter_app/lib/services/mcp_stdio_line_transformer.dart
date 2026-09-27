import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// Raised when one MCP stdio line exceeds the byte cap.
///
/// The Android reader enforces the same bound on the same pipes; this is the
/// desktop half of that contract. An over-limit line is not truncated: a cut
/// JSON-RPC frame cannot be parsed, so the stream fails and the client stops
/// the child instead of buffering the rest of it.
class McpLineTooLongException implements Exception {
  final String streamName;
  final int limitBytes;

  const McpLineTooLongException(this.streamName, this.limitBytes);

  @override
  String toString() => 'MCP $streamName line exceeded $limitBytes UTF-8 bytes';
}

/// Turns a byte stream into lines with a hard cap on one line.
///
/// utf8.decoder followed by LineSplitter holds a whole line before the split
/// happens, so a child that never sends a newline (or that sends one enormous
/// line) grows native memory without bound. This transformer counts the bytes
/// of the line it is still assembling and fails the stream with
/// [McpLineTooLongException] as soon as the cap is passed.
///
/// Splitting matches [LineSplitter] for the terminators an MCP server emits
/// (line feed, carriage return, or both together), including a final line that
/// is not terminated.
class BoundedUtf8LineTransformer
    extends StreamTransformerBase<List<int>, String> {
  static const int _lf = 0x0A;
  static const int _cr = 0x0D;

  /// Largest number of UTF-8 bytes one line may occupy.
  final int maxLineBytes;

  /// Stream name used in the failure message (stdout or stderr).
  final String streamName;

  const BoundedUtf8LineTransformer({
    required this.maxLineBytes,
    this.streamName = 'stdout',
  });

  @override
  Stream<String> bind(Stream<List<int>> stream) {
    final controller = StreamController<String>();
    StreamSubscription<List<int>>? subscription;
    var pending = BytesBuilder(copy: false);
    var pendingLength = 0;
    var skipLeadingLf = false;
    var finished = false;

    void finish() {
      finished = true;
      pending = BytesBuilder(copy: false);
      pendingLength = 0;
      controller.close();
      unawaited(subscription?.cancel());
    }

    void fail() {
      if (finished) return;
      // Drop what was buffered: the caller is about to stop the child.
      controller.addError(McpLineTooLongException(streamName, maxLineBytes));
      finish();
    }

    void emit(List<int> bytes) =>
        controller.add(utf8.decode(bytes, allowMalformed: true));

    // A failed decode of an empty line yields an empty string, exactly like
    // LineSplitter's empty segments.

    void handleChunk(List<int> chunk) {
      if (finished) return;
      var start = 0;
      for (var index = 0; index < chunk.length; index++) {
        final byte = chunk[index];
        // The LF half of a CRLF whose CR already ended a line: part of the same
        // terminator, never a line of its own.
        if (byte == _lf && skipLeadingLf && index == start) {
          skipLeadingLf = false;
          start = index + 1;
          continue;
        }
        if (byte != _lf && byte != _cr) continue;
        if (index > start) {
          pending.add(chunk.sublist(start, index));
          pendingLength += index - start;
        }
        if (pendingLength > maxLineBytes) {
          fail();
          return;
        }
        final line = pending.takeBytes();
        pending = BytesBuilder(copy: false);
        pendingLength = 0;
        skipLeadingLf = byte == _cr;
        emit(line);
        if (finished) return;
        start = index + 1;
      }
      if (start < chunk.length) {
        pending.add(chunk.sublist(start));
        pendingLength += chunk.length - start;
        if (pendingLength > maxLineBytes) fail();
      }
    }

    subscription = stream.listen(
      handleChunk,
      onError: (Object error, StackTrace stackTrace) {
        if (finished) return;
        finished = true;
        controller.addError(error, stackTrace);
        controller.close();
      },
      onDone: () {
        if (finished) return;
        finished = true;
        // A final line without a terminator is still a line.
        if (pendingLength > 0) emit(pending.takeBytes());
        pending = BytesBuilder(copy: false);
        pendingLength = 0;
        controller.close();
      },
      cancelOnError: false,
    );
    controller.onCancel = () => subscription?.cancel();
    return controller.stream;
  }
}
