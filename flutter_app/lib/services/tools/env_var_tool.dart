import '../../l10n/app_strings.dart';
import '../preferences_service.dart';
import 'tool_registry.dart';

class EnvVarTool extends Tool {
  final PreferencesService _prefs;

  EnvVarTool([PreferencesService? prefs])
      : _prefs = prefs ?? PreferencesService();

  @override
  String get name => 'set_env_var';

  @override
  String get description =>
      'Set or delete an environment variable in ClawChat settings. '
      'Values are stored for purpose-specific integrations; general shell '
      'commands never receive them. '
      'Do not use this to expose secret values in chat output.';

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'Environment variable name, e.g. GITHUB_TOKEN',
          },
          'value': {
            'type': 'string',
            'description':
                'Environment variable value. If omitted or empty, the variable is deleted.',
          },
          'action': {
            'type': 'string',
            'enum': ['set', 'delete'],
            'description': 'set or delete. Defaults to set.',
          },
        },
        'required': ['name'],
      };

  static final _namePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
  static const _maxNameLength = 128;
  static const _maxValueLength = 8192;
  static const _maxEnvVarCount = 100;
  static const _protectedNames = {
    'HOME',
    'USER',
    'PATH',
    'SHELL',
    'TERM',
    'TMPDIR',
    'COLUMNS',
    'LINES',
    'PROOT_TMP_DIR',
    'PROOT_LOADER',
    'PROOT_LOADER_32',
    'LD_LIBRARY_PATH',
  };

  @override
  Future<String> execute(Map<String, dynamic> input) async {
    final nameValue = input['name'];
    if (nameValue is! String || nameValue.isEmpty) {
      return AppStrings.envVarNameRequired;
    }

    final name = nameValue;
    if (name.length > _maxNameLength) {
      return AppStrings.envVarInvalidName;
    }
    if (!_namePattern.hasMatch(name)) {
      return AppStrings.envVarInvalidName;
    }
    if (_protectedNames.contains(name)) {
      return AppStrings.envVarProtectedName(name);
    }

    final actionValue = input['action'];
    final action = actionValue == null
        ? 'set'
        : actionValue.toString().trim().toLowerCase();
    if (action != 'set' && action != 'delete') {
      return AppStrings.envVarInvalidAction;
    }

    await _prefs.init();
    final updated = Map<String, String>.from(_prefs.envVars);
    final value = input['value']?.toString() ?? '';
    final shouldDelete = action == 'delete' || value.isEmpty;

    if (shouldDelete) {
      updated.remove(name);
      _prefs.envVars = updated;
      return AppStrings.envVarDeleted(name);
    }

    if (value.length > _maxValueLength) {
      return '环境变量值过长（最大 $_maxValueLength 字符）';
    }
    if (!updated.containsKey(name) && updated.length >= _maxEnvVarCount) {
      return '环境变量数量已达上限（$_maxEnvVarCount 个）';
    }

    updated[name] = value;
    _prefs.envVars = updated;
    return '${AppStrings.envVarSet(name)}（值已隐藏，不会回显）';
  }
}
