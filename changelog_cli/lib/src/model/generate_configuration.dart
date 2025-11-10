// ignore_for_file: avoid_equals_and_hash_code_on_mutable_classes, avoid_dynamic_calls

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:equatable/equatable.dart';
import 'package:intl/intl.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:yaml/yaml.dart';

enum GroupBy {
  dateAsc,
  dateDesc,
  scopeAsc,
  scopeDesc,
}

GroupBy getGroupByFromString(String input) {
  switch (input) {
    case 'date-asc':
      return GroupBy.dateAsc;
    case 'date-desc':
      return GroupBy.dateDesc;
    case 'scope-asc':
      return GroupBy.scopeAsc;
    case 'scope-desc':
      return GroupBy.scopeDesc;
    default:
      return GroupBy.dateAsc;
  }
}

enum PrinterType { simple, markdown, slackMarkdown }

PrinterType getPrinterFromString(String input) {
  switch (input) {
    case 'simple':
      return PrinterType.simple;
    case 'markdown':
      return PrinterType.markdown;
    case 'slack-markdown':
      return PrinterType.slackMarkdown;
    default:
      return PrinterType.simple;
  }
}

class GenerateConfiguration extends Equatable {
  const GenerateConfiguration({
    required this.start,
    required this.end,
    required this.path,
    required this.include,
    required this.printer,
    required this.groupBy,
    required this.auto,
    required this.autoGlobPattern,
    required this.version,
    required this.limit,
    required this.dateFormat,
    required this.jiraUrl,
    required this.jiraProjectKey,
    required this.output,
  });

  factory GenerateConfiguration.fromArgs(
    ArgResults args, [
    Logger? logger,
  ]) {
    // Load configuration from files (if they exist)
    final configData = _loadConfigurationFiles(logger);

    final start = _getArgValue(args, 'start', configData['changelog']?['start'] as String?, logger);
    final end = _getArgValue(args, 'end', configData['changelog']?['end'] as String?, logger);
    final path = _getArgValue(args, 'path', configData['changelog']?['path'] as String?, logger) ?? '.';

    // Handle include list - merge config file with CLI args
    var include = <String>[];
    final configInclude = configData['changelog']?['include'];
    if (configInclude is List) {
      include = configInclude.cast<String>();
    }
    if (include.isEmpty) {
      final argsInclude = args['include'] as List<String>?;
      if (argsInclude != null && argsInclude.isNotEmpty) {
        include = argsInclude;
      }
    }

    final printer = _getArgValue(args, 'printer', configData['changelog']?['printer'] as String?, logger) ?? 'simple';
    final groupBy = _getArgValue(args, 'group-by', configData['changelog']?['group_by'] as String?, logger);
    final auto = _getBoolArgValue(args, 'auto', configData['changelog']?['auto'] as bool?, logger) ?? false;
    final autoGlobPattern =
        _getArgValue(args, 'auto-tag-glob-pattern', configData['changelog']?['auto_tag_glob_pattern'] as String?, logger) ?? '';
    final version = _getArgValue(args, 'version', configData['changelog']?['version'] as String?, logger) ?? '';

    final limitArg = _getArgValue(args, 'limit', null, logger);
    final limitConfig = configData['changelog']?['limit'];
    var limit = 0;
    if (limitArg != null && limitArg.isNotEmpty) {
      limit = int.tryParse(limitArg) ?? 0;
    } else if (limitConfig != null) {
      limit = limitConfig is int ? limitConfig : (int.tryParse(limitConfig.toString()) ?? 0);
    }

    final dateFormat = _getArgValue(args, 'date-format', configData['changelog']?['date_format'] as String?, logger) ?? '';
    final jiraArg = _getArgValue(args, 'jira-url', configData['changelog']?['jira_url'] as String?, logger);
    final jiraUrl = jiraArg ?? configData['changelog']?['jira_url'] as String? ?? '';
    final jiraProjectKeyArg = _getArgValue(args, 'jira-project-key', configData['changelog']?['jira_project_key'] as String?, logger);
    final jiraProjectKey = jiraProjectKeyArg ?? configData['changelog']?['jira_project_key'] as String? ?? '';
    final outputArg = _getArgValue(args, 'output', null, logger);
    final output = outputArg ?? configData['changelog']?['output'] as String? ?? '';

    final matchingPrinter = getPrinterFromString(printer);
    final matchingGroupBy = getGroupByFromString(groupBy ?? '');
    logger?.detail('Using printer: $matchingPrinter');
    logger?.detail('Using groupBy: $matchingGroupBy');

    final locale =
        _getArgValue(args, 'date-format-locale', configData['changelog']?['date_format_locale'] as String?, logger) ?? 'en_US';
    Intl.defaultLocale = locale;

    return GenerateConfiguration(
      start: start ?? '',
      end: end ?? '',
      path: path,
      include: include.isNotEmpty ? include : ['feat', 'fix', 'refactor', 'perf'],
      printer: matchingPrinter,
      groupBy: matchingGroupBy,
      auto: auto,
      autoGlobPattern: autoGlobPattern,
      version: version,
      limit: limit,
      dateFormat: dateFormat,
      jiraUrl: jiraUrl,
      jiraProjectKey: jiraProjectKey,
      output: output,
    );
  }

  /// Helper method to get argument value with proper precedence:
  /// 1. Explicitly provided argument (not just default value)
  /// 2. Config file value
  /// 3. null (so caller can provide final fallback)
  static String? _getArgValue(ArgResults args, String key, String? configValue, [Logger? logger]) {
    // Check if the argument was explicitly provided (not just using default)
    if (args.wasParsed(key)) {
      final value = args[key] as String?;
      // Return the explicit value even if it's empty string
      logger?.detail('Argument "$key" explicitly provided with value: $value');
      return value;
    }
    // If not explicitly provided, use config file value
    logger?.detail('Argument "$key" not explicitly provided, using config value: $configValue');
    return configValue;
  }

  /// Helper method for boolean values
  static bool? _getBoolArgValue(ArgResults args, String key, bool? configValue, [Logger? logger]) {
    if (args.wasParsed(key)) {
      final value = args[key] as bool?;
      logger?.detail('Argument "$key" explicitly provided with value: $value');
      return value;
    }
    logger?.detail('Argument "$key" not explicitly provided, using config value: $configValue');
    return configValue;
  }

  /// Loads configuration from various config files in order of precedence:
  /// 1. .changelog_cli.yaml
  /// 2. .changelogrc (JSON)
  /// 3. ~/.changelog_cli.yaml (global)
  /// 4. ~/.changelogrc (global JSON)
  static Map<String, dynamic> _loadConfigurationFiles([Logger? logger]) {
    final configFiles = [
      '.changelog_cli.yaml',
      '.changelogrc',
      '${_getHomeDirectory()}/.changelog_cli.yaml',
      '${_getHomeDirectory()}/.changelogrc',
    ];

    for (final configPath in configFiles) {
      final file = File(configPath);
      if (file.existsSync()) {
        logger?.detail('Loading configuration from $configPath');
        try {
          final content = file.readAsStringSync();
          if (configPath.endsWith('.yaml') || configPath.endsWith('.yml')) {
            final yamlDoc = loadYaml(content);
            if (yamlDoc is Map) {
              logger?.detail('Parsed YAML configuration: $yamlDoc');
              return Map<String, dynamic>.from(yamlDoc);
            }
          } else {
            // Assume JSON for .changelogrc
            final jsonDoc = jsonDecode(content);
            if (jsonDoc is Map) {
              logger?.detail('Parsed JSON configuration: $jsonDoc');
              return Map<String, dynamic>.from(jsonDoc);
            }
          }
        } catch (e) {
          logger?.err('Failed to parse configuration file $configPath: $e');
          // Silently continue to next config file if parsing fails
          continue;
        }
      }
    }

    return {};
  }

  static String _getHomeDirectory() {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    return home ?? '';
  }

  final String start;
  final String end;
  final String path;
  final List<String> include;
  final PrinterType printer;
  final GroupBy groupBy;
  final bool auto;
  final String autoGlobPattern;
  final String version;
  final int limit;
  final String dateFormat;
  final String jiraUrl;
  final String jiraProjectKey;
  final String output;

  String formatDateTime(DateTime? date) {
    if (date == null || dateFormat.isEmpty) {
      return '';
    }
    return DateFormat(dateFormat).format(date);
  }

  @override
  bool? get stringify => true;

  @override
  List<Object?> get props => [
    start,
    end,
    path,
    include,
    printer,
    groupBy,
    auto,
    autoGlobPattern,
    version,
    limit,
    dateFormat,
    jiraUrl,
    jiraProjectKey,
    output,
  ];
}
