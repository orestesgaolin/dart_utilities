import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

/// {@template config_command}
/// `changelog_cli config`
///
/// A [Command] to manage configuration files
/// {@endtemplate}
class ConfigCommand extends Command<int> {
  /// {@macro config_command}
  ConfigCommand({
    required Logger logger,
  }) : _logger = logger {
    argParser
      ..addFlag(
        'init',
        help: 'Initialize a new configuration file',
        defaultsTo: false,
      )
      ..addOption(
        'format',
        abbr: 'f',
        help: 'Configuration file format',
        allowed: ['yaml', 'json'],
        defaultsTo: 'yaml',
      )
      ..addFlag(
        'global',
        abbr: 'g',
        help: 'Create global configuration file in home directory',
        defaultsTo: false,
      );
  }

  @override
  String get description => 'Manage configuration files for changelog generation';

  @override
  String get name => 'config';

  final Logger _logger;

  @override
  Future<int> run() async {
    if (argResults == null) {
      return ExitCode.usage.code;
    }

    final isInit = argResults!['init'] as bool;
    final format = argResults!['format'] as String;
    final isGlobal = argResults!['global'] as bool;

    if (isInit) {
      return _initConfig(format, isGlobal);
    }

    _logger.info('Use --init to create a new configuration file');
    return ExitCode.success.code;
  }

  Future<int> _initConfig(String format, bool isGlobal) async {
    final fileName = format == 'yaml' ? '.changelog_cli.yaml' : '.changelogrc';
    final filePath = isGlobal ? '${_getHomeDirectory()}/$fileName' : fileName;

    final file = File(filePath);

    if (file.existsSync()) {
      final overwrite = _logger.confirm(
        'Configuration file already exists at $filePath. Overwrite?',
      );
      if (!overwrite) {
        _logger.info('Configuration file creation cancelled');
        return ExitCode.success.code;
      }
    }

    try {
      final content = format == 'yaml' ? _getYamlTemplate() : _getJsonTemplate();
      await file.writeAsString(content);

      _logger
        ..success('Configuration file created at $filePath')
        ..info('Edit the file to customize your changelog generation settings');

      return ExitCode.success.code;
    } catch (e) {
      _logger.err('Failed to create configuration file: $e');
      return ExitCode.ioError.code;
    }
  }

  String _getYamlTemplate() {
    return '''
# Changelog CLI Configuration
# This file can be named .changelog_cli.yaml and placed in your project root
# or home directory

changelog:
  # Git reference settings
  start: ""  # Start git reference (e.g. commit SHA or tag)
  end: ""    # End git reference (e.g. commit SHA or tag)
  path: "."  # Path to the git repository or folder

  # Changelog content settings
  include:   # List of conventional commit types to include
    - feat
    - fix
    - refactor
    - perf

  # Output settings
  printer: simple  # Output format: simple, markdown, slack-markdown
  version: ""      # Version to display in changelog header
  limit: 0         # Max length of changelog (0 = no limit)

  # Grouping and formatting
  group_by: ""           # Group entries: date-asc, date-desc, scope-asc, scope-desc
  date_format: ""        # Date format (e.g. yyyy-MM-dd)
  date_format_locale: en_US

  # Auto-detection settings
  auto: false                    # Automatically detect previous tag
  auto_tag_glob_pattern: ""      # Pattern for auto tag detection

  # Integration settings
  jira_url: ""          # JIRA URL for issue linking
  jira_project_key: ""  # JIRA project key (e.g. AB, VA) - if not set, matches any valid ticket
  output: ""            # Output file path
''';
  }

  String _getJsonTemplate() {
    return '''
{
  "_comment": "Changelog CLI Configuration - JSON format",
  "_comment2": "This file can be named .changelogrc and placed in your project root or home directory",
  
  "changelog": {
    "start": "",
    "end": "",
    "path": ".",
    
    "include": [
      "feat",
      "fix", 
      "refactor",
      "perf"
    ],
    
    "printer": "simple",
    "version": "",
    "limit": 0,
    
    "group_by": "",
    "date_format": "",
    "date_format_locale": "en_US",
    
    "auto": false,
    "auto_tag_glob_pattern": "",
    
    "jira_url": "",
    "jira_project_key": "",
    "output": ""
  }
}''';
  }

  String _getHomeDirectory() {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    return home ?? '';
  }
}
