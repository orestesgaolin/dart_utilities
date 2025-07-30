// ignore_for_file: avoid_equals_and_hash_code_on_mutable_classes, avoid_dynamic_calls

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:intl/intl.dart';
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

class GenerateConfiguration {
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
  });

  factory GenerateConfiguration.fromArgs(
    ArgResults args,
  ) {
    // Load configuration from files (if they exist)
    final configData = _loadConfigurationFiles();

    final start = args['start'] as String? ?? configData['changelog']?['start'] as String?;
    final end = args['end'] as String? ?? configData['changelog']?['end'] as String?;
    final path = args['path'] as String? ?? configData['changelog']?['path'] as String?;

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

    final printer = args['printer'] as String? ?? configData['changelog']?['printer'] as String?;
    final groupBy = args['group-by'] as String? ?? configData['changelog']?['group_by'] as String?;
    final auto = args['auto'] as bool? ?? configData['changelog']?['auto'] as bool?;
    final autoGlobPattern =
        args['auto-tag-glob-pattern'] as String? ?? configData['changelog']?['auto_tag_glob_pattern'] as String?;
    final version = args['version'] as String? ?? configData['changelog']?['version'] as String?;

    final limitArg = args['limit'] as String?;
    final limitConfig = configData['changelog']?['limit'];
    int? limit;
    if (limitArg != null && limitArg.isNotEmpty) {
      limit = int.tryParse(limitArg);
    } else if (limitConfig != null) {
      limit = limitConfig is int ? limitConfig : int.tryParse(limitConfig.toString());
    }

    final dateFormat = args['date-format'] as String? ?? configData['changelog']?['date_format'] as String?;
    final jiraUrl = args['jira-url'] as String? ?? configData['changelog']?['jira_url'] as String?;

    final matchingPrinter = getPrinterFromString(printer ?? '');
    final matchingGroupBy = getGroupByFromString(groupBy ?? '');

    final locale =
        args['date-format-locale'] as String? ?? configData['changelog']?['date_format_locale'] as String? ?? 'en_US';
    Intl.defaultLocale = locale;

    return GenerateConfiguration(
      start: start ?? '',
      end: end ?? '',
      path: path ?? '.',
      include: include.isNotEmpty ? include : ['feat', 'fix', 'refactor', 'perf'],
      printer: matchingPrinter,
      groupBy: matchingGroupBy,
      auto: auto ?? false,
      autoGlobPattern: autoGlobPattern ?? '',
      version: version ?? '',
      limit: limit ?? 0,
      dateFormat: dateFormat ?? '',
      jiraUrl: jiraUrl ?? '',
    );
  }

  /// Loads configuration from various config files in order of precedence:
  /// 1. .changelog_cli.yaml
  /// 2. .changelogrc (JSON)
  /// 3. ~/.changelog_cli.yaml (global)
  /// 4. ~/.changelogrc (global JSON)
  static Map<String, dynamic> _loadConfigurationFiles() {
    final configFiles = [
      '.changelog_cli.yaml',
      '.changelogrc',
      '${_getHomeDirectory()}/.changelog_cli.yaml',
      '${_getHomeDirectory()}/.changelogrc',
    ];

    for (final configPath in configFiles) {
      final file = File(configPath);
      if (file.existsSync()) {
        try {
          final content = file.readAsStringSync();
          if (configPath.endsWith('.yaml') || configPath.endsWith('.yml')) {
            final yamlDoc = loadYaml(content);
            if (yamlDoc is Map) {
              return Map<String, dynamic>.from(yamlDoc);
            }
          } else {
            // Assume JSON for .changelogrc
            final jsonDoc = jsonDecode(content);
            if (jsonDoc is Map) {
              return Map<String, dynamic>.from(jsonDoc);
            }
          }
        } catch (e) {
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

  String formatDateTime(DateTime? date) {
    if (date == null || dateFormat.isEmpty) {
      return '';
    }
    return DateFormat(dateFormat).format(date);
  }

  @override
  int get hashCode => Object.hash(
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
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GenerateConfiguration &&
          runtimeType == other.runtimeType &&
          start == other.start &&
          end == other.end &&
          path == other.path &&
          include == other.include &&
          printer == other.printer &&
          groupBy == other.groupBy &&
          auto == other.auto &&
          autoGlobPattern == other.autoGlobPattern &&
          version == other.version &&
          limit == other.limit &&
          dateFormat == other.dateFormat &&
          jiraUrl == other.jiraUrl;
}
