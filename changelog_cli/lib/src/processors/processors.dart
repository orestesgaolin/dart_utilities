import 'package:changelog_cli/src/model/model.dart';
import 'package:collection/collection.dart';

class Preprocessor {
  Preprocessor();

  static List<ChangelogEntryGroup> processGitHistory(
    List<ChangelogEntry> entries,
    GenerateConfiguration configuration,
  ) {
    // group by configuration.groupBy
    switch (configuration.groupBy) {
      case GroupBy.dateAsc:
        entries.sort((a, b) {
          if (a.date == null && b.date == null) {
            return 0;
          }
          if (a.date == null) {
            return 1;
          }
          if (b.date == null) {
            return -1;
          }
          return a.date!.compareTo(b.date!);
        });
        break;
      case GroupBy.dateDesc:
        entries.sort((a, b) {
          if (a.date == null && b.date == null) {
            return 0;
          }
          if (a.date == null) {
            return -1;
          }
          if (b.date == null) {
            return 1;
          }
          return b.date!.compareTo(a.date!);
        });
        break;
      case GroupBy.scopeAsc:
        entries.sort(
          (a, b) => a.conventionalCommit.scopes
              .join()
              .compareTo(b.conventionalCommit.scopes.join()),
        );
        break;
      case GroupBy.scopeDesc:
        entries.sort(
          (a, b) => b.conventionalCommit.scopes
              .join()
              .compareTo(a.conventionalCommit.scopes.join()),
        );
        break;
    }

    // could be optimized
    final groupedEntries = entries.groupListsBy((e) => e.type);

    final filteredEntries = <ChangelogEntryGroup>[];

    for (final type in configuration.include) {
      final entriesOfType = groupedEntries[type];

      if (entriesOfType != null) {
        filteredEntries.add(
          ChangelogEntryGroup(entries: entriesOfType, type: type),
        );
      }
    }

    return filteredEntries;
  }
}

class CommitMessageProcessor {
  static String processJiraUrls(
    String message,
    GenerateConfiguration configuration,
    String Function(String url, String title) urlBuilder,
  ) {
    const regex = r'\b[A-Z][A-Z0-9_]+-[1-9][0-9]*';
    final matches = RegExp(regex).allMatches(message);
    if (matches.isEmpty) {
      return message;
    }
    final url = configuration.jiraUrl;

    var updatedMessage = message;
    for (final match in matches) {
      final ticket = match.group(0);
      if (ticket == null) {
        continue;
      }
      final uri = Uri.parse(url);
      if (uri.scheme != 'https') {
        throw Exception('Jira URL must be https');
      }
      if (uri.host.isEmpty) {
        throw Exception('Jira URL must have host');
      }
      final newUri = uri.appendUriComponent(ticket);

      updatedMessage = message.replaceAll(
        ticket,
        urlBuilder(newUri.toString(), ticket),
      );
    }
    return updatedMessage;
  }
}

extension UriExtension on Uri {
  /// Appends a list of path components to the URI.
  Uri appendUriComponents(
    List<String> components, {
    bool isDirectory = false,
  }) {
    var s = toString();
    if (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    for (final comp in components) {
      // ignore: use_string_buffers
      s += '/${Uri.encodeComponent(comp)}';
    }
    if (isDirectory) {
      s += '/';
    }
    return Uri.parse(s);
  }

  /// Appends a path component to the URI.
  Uri appendUriComponent(String component, {bool isDirectory = false}) {
    return appendUriComponents([component], isDirectory: isDirectory);
  }
}
