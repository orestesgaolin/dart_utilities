// ignore_for_file: cascade_invocations

import 'package:changelog_cli/src/model/changelog_entry.dart';
import 'package:changelog_cli/src/printers/printers.dart';
import 'package:collection/collection.dart';

class MarkdownPrinter extends Printer {
  MarkdownPrinter();

  @override
  String print({
    required List<ChangelogEntry> entries,
    String? version,
    required List<String> types,
  }) {
    final groupedBy = entries.groupListsBy((e) => e.type);
    final buffer = StringBuffer();
    if (version != null && version.isNotEmpty) {
      buffer.writeln('## $version');
    } else {
      buffer.writeln('## Changes');
    }
    buffer.writeln();

    for (final type in types) {
      final group = groupedBy[type];
      if (group != null) {
        final title = mapping[type] ?? type;
        buffer.writeln('**$title**');
        buffer.writeln();
        for (final entry in group) {
          buffer.write('- ');
          if (entry.conventionalCommit.scopes.isNotEmpty) {
            final scopes = entry.conventionalCommit.scopes.join(', ');
            buffer.write('**$scopes**: ');
          }
          buffer.writeln(entry.message);
        }
        buffer.writeln();
      }
    }
    return buffer.toString();
  }
}
