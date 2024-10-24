// ignore_for_file: cascade_invocations

import 'package:changelog_cli/src/model/changelog_entry.dart';
import 'package:changelog_cli/src/printers/printers.dart';
import 'package:changelog_cli/src/processors/processors.dart';
import 'package:collection/collection.dart';

/// Provides syntax that works with Slack markdown blocks
///
/// See some differences between markdown and slack markdown:
/// https://www.markdownguide.org/tools/slack/
class SlackMarkdownPrinter extends Printer {
  SlackMarkdownPrinter({required super.configuration});

  @override
  String print({
    required List<ChangelogEntryGroup> entries,
  }) {
    final version = configuration.version;
    final types = configuration.include;

    final buffer = StringBuffer();
    if (version.isNotEmpty) {
      buffer.writeln('*$version*');
    } else {
      buffer.writeln('*Changes*');
    }
    buffer.writeln();

    for (final type in types) {
      final group = entries.firstWhereOrNull((t) => t.type == type);
      if (group != null) {
        final title = typeNameMapping[type] ?? type;
        buffer.writeln('*$title*');
        buffer.writeln();
        for (final entry in group.entries) {
          buffer.write('- ');
          if (entry.conventionalCommit.scopes.isNotEmpty) {
            final scopes = entry.conventionalCommit.scopes.join(', ');
            buffer.write('*$scopes*: ');
          }

          var message = entry.message;
          if (configuration.jiraUrl.isNotEmpty) {
            message = CommitMessageProcessor.processJiraUrls(
              message,
              configuration,
              (url, title) {
                return '<$url|$title>';
              },
            );
          }

          if (entry.date != null && configuration.dateFormat.isNotEmpty) {
            buffer.write(message);
            final dateFormatted = configuration.formatDateTime(entry.date);
            buffer.writeln(' ($dateFormatted)');
          } else {
            buffer.writeln(message);
          }
        }
        buffer.writeln();
      }
    }
    return buffer.toString();
  }
}
