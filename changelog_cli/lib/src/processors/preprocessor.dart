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
