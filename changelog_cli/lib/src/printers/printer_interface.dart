import 'package:changelog_cli/src/model/model.dart';

// ignore: one_member_abstracts
abstract class Printer {
  Printer({required this.configuration});

  final GenerateConfiguration configuration;

  String print({
    required List<ChangelogEntryGroup> entries,
  });
}

const typeNameMapping = {
  'feat': 'Features',
  'fix': 'Bug Fixes',
  'perf': 'Performance Improvements',
  'refactor': 'Refactor',
  'test': 'Tests',
  'docs': 'Documentation',
  'chore': 'Chores',
  'build': 'Build System',
  'ci': 'CI',
};
