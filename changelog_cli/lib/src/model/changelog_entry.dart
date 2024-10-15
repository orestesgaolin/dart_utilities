import 'package:conventional_commit/conventional_commit.dart';
import 'package:equatable/equatable.dart';
import 'package:git/git.dart';

class ChangelogEntry extends Equatable {
  const ChangelogEntry({
    required this.conventionalCommit,
    required this.ref,
    required this.commit,
    required this.date,
  });

  final ConventionalCommit conventionalCommit;
  final String ref;
  final Commit commit;
  final DateTime? date;

  String get message =>
      conventionalCommit.description ?? conventionalCommit.header;
  String get type => conventionalCommit.type ?? '';

  @override
  List<Object?> get props => [
        conventionalCommit,
        ref,
        commit,
        date,
      ];
}

class ChangelogEntryGroup extends Equatable {
  const ChangelogEntryGroup({
    required this.entries,
    required this.type,
  });

  final List<ChangelogEntry> entries;
  final String type;

  @override
  List<Object?> get props => [
        entries,
        type,
      ];
}
