import '../native_bridge.dart';
import 'tool_registry.dart';

class BashTool extends Tool {
  @override
  String get name => 'bash';

  @override
  String get description =>
      'Execute a shell command in the Alpine Linux environment. '
      'Commands run inside a proot container with /root/workspace as the default directory. '
      'Shared Android storage is not mounted for agent commands. '
      'Use this for file operations, running scripts, installing packages, etc. '
      'Sensitive-file blocking is defense-in-depth only and must not be treated as a complete sandbox.';

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'command': {
            'type': 'string',
            'description': 'The bash command to execute',
          },
          'timeout': {
            'type': 'integer',
            'description': 'Timeout in seconds (default: 120)',
          },
        },
        'required': ['command'],
      };

  // NOTE: This blocklist is defense-in-depth only, NOT a complete security
  // solution. Determined attackers can bypass these patterns through encoding,
  // obfuscation, or other creative means. Do not rely on this as the sole
  // security control. A proper solution requires user confirmation for
  // sensitive operations.
  static final _blockedPatterns = RegExp(
    r'rm\s+(-[a-zA-Z]*f[a-zA-Z]*\s+)?/(?!root/workspace/)'
    r'|'
    r'mkfs\s|'
    r'dd\s+if=/dev/|'
    r':\s*\(\s*\)\s*\{[^}]*\|[^}]*\}|'
    r'>\s*/dev/sd|'
    r'chmod\s+-R\s+777\s+/|'
    r'wget\s.*\|\s*sh|'
    r'curl\s.*\|\s*(ba)?sh|'
    r'nc\s+-l|'
    r'python.*-c.*import\s+os|'
    r'eval\s*\(|'
    r'exec\s*>/dev/tcp|'
    r'base64\s+(-d|--decode).*\|\s*(sh|bash)|' // base64 decode piped to shell
    r'python[23]?\s+-c\s|'
    r'perl\s+-e\s|'
    r'ruby\s+-e\s|'
    r'node\s+-e\s|'
    r'php\s+-r\s|'
    r'\bsource\s+/dev/tcp|'
    r'\.\s+/dev/tcp|'
    r'bash\s+-i\s|'
    r'\beval\s|' // eval command (shell built-in)
    r'printf\s.*\|\s*(sh|bash)\b|' // printf piped to shell
    r'echo\s.*\|\s*(sh|bash)\b', // echo piped to shell
    caseSensitive: false,
  );

  static final _blockedCommands = RegExp(
    r'(?:^|;\s*|&&\s*|\|\|\s*|\|\s*|`\s*|\$\()\s*'
    r'(rm\s+-[a-zA-Z]*rf?\s+/|rm\s+/\s|reboot|shutdown|init\s+0|'
    r'halt|poweroff|mkfs|fdisk|parted|'
    r'iptables\s+-F|'
    r'passwd\s|userdel|groupdel|'
    r'kill\s+-9\s+1\b)',
    caseSensitive: false,
  );

  static final _sensitiveFiles = RegExp(
    r'\b(cat|less|more|head|tail|grep|egrep|fgrep|rg|awk|sed|od|xxd|strings)\b'
    r'[^\n;&|]*'
    r'((^|[\s/=])\.env(\b|[.*?[\]{}-])|/etc/shadow|/etc/passwd|'
    r'\.ssh/|id_rsa\b|id_ed25519\b|\.gnupg/|\.aws/credentials|'
    r'\.netrc\b|\.(pem|key)\b|'
    r'(^|[\s/=])\.(secret|secrets|credential|credentials)(\b|[./])|'
    r'(^|[\s/=])(secret|secrets|credential|credentials)\.(json|env|pem|key)\b)'
    r'|'
    r'\b(cp|mv|install|dd|tar|zip|unzip|base64)\b'
    r'[^\n;&|]*'
    r'((^|[\s/=])\.env(\b|[.*?[\]{}-])|/etc/shadow|/etc/passwd|'
    r'\.ssh/|id_rsa\b|id_ed25519\b|\.gnupg/|\.aws/credentials|'
    r'\.netrc\b|\.(pem|key)\b|'
    r'(^|[\s/=])\.(secret|secrets|credential|credentials)(\b|[./])|'
    r'(^|[\s/=])(secret|secrets|credential|credentials)\.(json|env|pem|key)\b)',
    caseSensitive: false,
  );

  bool _isCommandBlocked(String command) {
    final normalized = command.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (_blockedPatterns.hasMatch(normalized)) return true;
    if (_blockedCommands.hasMatch(normalized)) return true;
    if (_sensitiveFiles.hasMatch(normalized)) return true;
    return false;
  }

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    return _execute(input);
  }

  Future<String> _execute(Map<String, dynamic> input) async {
    final command = input['command'] as String;
    final timeout = (input['timeout'] as num?)?.toInt() ?? 120;

    // Command length limit to prevent abuse
    if (command.length > 10000) {
      return 'Error: Command too long (${command.length} chars, max 10000).';
    }

    if (_isCommandBlocked(command)) {
      return 'Error: Command blocked for security reasons. '
          'Potentially dangerous commands (rm -rf /, mkfs, dd, fork bombs, etc.) are not allowed.';
    }

    // Prepend workspace cd for commands that don't explicitly set their own directory
    const workingDir = '/root/workspace';
    final cdPrefix = command.trimLeft().startsWith('cd ')
        ? ''
        : 'cd $workingDir 2>/dev/null; ';
    // Raw user-configured secrets are never injected into a general-purpose
    // shell. A future secret consumer must use a purpose-specific broker that
    // cannot echo, transform, persist, or export the value.
    final effectiveCommand = '$cdPrefix$command';

    try {
      final output = await NativeBridge.runInProot(
        effectiveCommand,
        timeout: timeout,
        mountStorage: false,
      );
      if (output.length > 50000) {
        return '${output.substring(0, 50000)}\n\n'
            '[Output truncated, original length: ${output.length} chars]';
      }
      return output;
    } catch (e) {
      return 'Error: $e';
    }
  }
}
