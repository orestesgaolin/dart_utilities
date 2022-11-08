import 'package:changelog_cli/src/model/model.dart';

// ignore: one_member_abstracts
abstract class Printer {
  String print({
    required List<ChangelogEntry> entries,
    String? version,
    required List<String> types,
  });
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
  'ci': 'CI',
};
