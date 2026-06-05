import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

import '../display/branches_app.dart';
import '../git/git_repo.dart';

/// Launches the interactive branch-cleanup UI. This is the default command.
class TuiCommand extends Command<void> {
  @override
  final name = 'tui';

  @override
  final description = 'Interactive UI to review and clean up local branches (default).';

  @override
  Future<void> run() async {
    final git = await GitRepo.discover(Directory.current.path);
    if (git == null) {
      stderr.writeln('Not inside a git repository.');
      exitCode = 1;
      return;
    }
    final name = await git.ownerRepoSlug() ?? p.basename(git.root);
    await runApp(GitBranchesApp(git: git, repoName: name));
  }
}
