// ignore_for_file: cascade_invocations

import 'package:changelog_cli/src/model/changelog_entry.dart';
import 'package:collection/collection.dart';

class SimplePrinter {
  SimplePrinter(this.types);

  final List<String> types;

  String print(List<ChangelogEntry> entries, String version) {
    final groupedBy = entries.groupListsBy((e) => e.type);
    final buffer = StringBuffer();
    buffer.writeln('## $version');
    buffer.writeln();
    for (final type in types) {
      final group = groupedBy[type];
      if (group != null) {
        final title = mapping[type] ?? type;
        buffer.writeln('**$title**');
        buffer.writeln();
        for (final entry in group) {
          buffer.writeln('- ${entry.message}');
        }
        buffer.writeln();
      }
    }
    return buffer.toString();
  }
}

const mapping = {
  'feat': 'Features',
  'fix': 'Bug Fixes',
  'perf': 'Performance Improvements',
  'refactor': 'Refactor',
  'test': 'Tests',
  'docs': 'Documentation',
  'chore': 'Chores',
  'build': 'Build System',
  'ci': 'Continuous Integration',
};
