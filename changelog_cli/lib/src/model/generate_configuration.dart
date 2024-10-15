// ignore_for_file: avoid_equals_and_hash_code_on_mutable_classes

import 'package:args/args.dart';
import 'package:intl/intl.dart';

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

enum PrinterType {
  simple,
  markdown,
  slackMarkdown;
}

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
  });

  factory GenerateConfiguration.fromArgs(
    ArgResults args,
  ) {
    final start = args['start'] as String?;
    final end = args['end'] as String?;
    final path = args['path'] as String?;
    final include = args['include'] as List<String>?;
    final printer = args['printer'] as String?;
    final groupBy = args['group-by'] as String?;
    final auto = args['auto'] as bool?;
    final autoGlobPattern = args['auto-tag-glob-pattern'] as String?;
    final version = args['version'] as String?;
    final limit = int.tryParse(args['limit'] as String? ?? '');
    final dateFormat = args['date-format'] as String?;

    final matchingPrinter = getPrinterFromString(printer ?? '');

    final matchingGroupBy = getGroupByFromString(groupBy ?? '');

    final locale = args['date-format-locale'] as String? ?? 'en_US';
    Intl.defaultLocale = locale;

    return GenerateConfiguration(
      start: start ?? '',
      end: end ?? '',
      path: path ?? '',
      include: include ?? [],
      printer: matchingPrinter,
      groupBy: matchingGroupBy,
      auto: auto ?? false,
      autoGlobPattern: autoGlobPattern ?? '',
      version: version ?? '',
      limit: limit ?? 0,
      dateFormat: dateFormat ?? '',
    );
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
          dateFormat == other.dateFormat;
}
