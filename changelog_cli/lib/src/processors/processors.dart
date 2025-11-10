import 'package:changelog_cli/src/model/model.dart';
import 'package:changelog_cli/src/processors/revert_detector.dart';
import 'package:collection/collection.dart';
import 'package:mason_logger/mason_logger.dart';

class Preprocessor {
  Preprocessor();

  static List<ChangelogEntryGroup> processGitHistory(
    List<ChangelogEntry> entries,
    GenerateConfiguration configuration, {
    Logger? logger,
  }) {
    final entriesWithReverts = RevertDetector.detectReverts(entries, logger: logger);

    // group by configuration.groupBy
    logger?.detail('Grouping changelog entries by ${configuration.groupBy}');
    switch (configuration.groupBy) {
      case GroupBy.dateAsc:
        entriesWithReverts.sort((ChangelogEntry a, ChangelogEntry b) {
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
      case GroupBy.dateDesc:
        entriesWithReverts.sort((ChangelogEntry a, ChangelogEntry b) {
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
      case GroupBy.scopeAsc:
        entriesWithReverts.sort(
          (ChangelogEntry a, ChangelogEntry b) =>
              a.conventionalCommit.scopes.join().compareTo(b.conventionalCommit.scopes.join()),
        );
      case GroupBy.scopeDesc:
        entriesWithReverts.sort(
          (ChangelogEntry a, ChangelogEntry b) =>
              b.conventionalCommit.scopes.join().compareTo(a.conventionalCommit.scopes.join()),
        );
    }

    // depending on the grouping:

    final groupedEntries = entriesWithReverts.groupListsBy((ChangelogEntry e) => e.type);

    final filteredEntries = <ChangelogEntryGroup>[];

    for (final type in configuration.include) {
      final entriesOfType = groupedEntries[type];
      logger?.detail('Found ${entriesOfType?.length ?? 0} entries of type $type');

      if (entriesOfType != null) {
        filteredEntries.add(
          ChangelogEntryGroup(entries: entriesOfType, type: type),
        );
      } else {
        logger?.detail('No entries of type $type found');
      }
    }

    // now group by respective configuration.groupBy
    if (configuration.groupBy != GroupBy.dateAsc && configuration.groupBy != GroupBy.dateDesc) {
      // if not grouping by date, we can just return the filtered entries
      return filteredEntries;
    }

    // TODO(orestesgaolin): implement grouping by date
    return filteredEntries;
  }
}

class CommitMessageProcessor {
  static String processJiraUrls(
    String message,
    GenerateConfiguration configuration,
    String Function(String url, String title) urlBuilder,
  ) {
    // If project key is specified, use it for targeted matching
    // Otherwise, use generic pattern that matches any valid Jira ticket format
    final regex = configuration.jiraProjectKey.isNotEmpty
        ? '\\b${configuration.jiraProjectKey}-[1-9][0-9]*'
        : r'\b[A-Z][A-Z0-9_]+-[1-9][0-9]*';
    
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
