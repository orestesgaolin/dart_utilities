import 'package:conventional_commit/conventional_commit.dart';
import 'package:equatable/equatable.dart';
import 'package:git/git.dart';

class ChangelogEntry extends Equatable {
  const ChangelogEntry({
    required this.conventionalCommit,
    required this.ref,
    required this.commit,
  });

  final ConventionalCommit conventionalCommit;
  final String ref;
  final Commit commit;

  String get message =>
      conventionalCommit.description ?? conventionalCommit.header;
  String get type => conventionalCommit.type ?? '';

  @override
  List<Object?> get props => [
        conventionalCommit,
        ref,
        commit,
      ];
}
