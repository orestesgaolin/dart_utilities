import 'dart:io';

import 'package:args/command_runner.dart';

import '../git/git_repo.dart';
import '../models.dart';

/// Prints local branches with their merge/stale/upstream status (no UI).
class ListCommand extends Command<void> {
  @override
  final name = 'list';

  @override
  final description = 'List local branches with merge and staleness status.';

  ListCommand() {
    argParser
      ..addFlag('merged',
          negatable: false, help: 'Only branches merged into the default branch.')
      ..addFlag('stale',
          negatable: false,
          help: 'Only unmerged branches with no activity in 60+ days.');
  }

  @override
  Future<void> run() async {
    final git = await GitRepo.discover(Directory.current.path);
    if (git == null) {
      stderr.writeln('Not inside a git repository.');
      exitCode = 1;
      return;
    }
    final onlyMerged = argResults!['merged'] as bool;
    final onlyStale = argResults!['stale'] as bool;

    var branches = await git.branches();
    branches.sort((a, b) => a.lastActivity.compareTo(b.lastActivity));

    bool isStale(BranchInfo b) =>
        !b.isEffectivelyMerged &&
        !b.isProtected &&
        DateTime.now().difference(b.lastActivity).inDays >= 60;

    if (onlyMerged) {
      branches =
          branches.where((b) => b.isEffectivelyMerged && !b.isProtected).toList();
    }
    if (onlyStale) branches = branches.where(isStale).toList();

    if (branches.isEmpty) {
      stdout.writeln('No matching branches.');
      return;
    }
    for (final b in branches) {
      final tags = <String>[
        if (b.isCurrent) 'current',
        if (b.isDefault && !b.isCurrent) 'default',
        if (b.isMerged && !b.isProtected) 'merged',
        if (b.isSquashMerged) 'squashed',
        if (isStale(b)) 'stale',
        if (b.upstreamGone) 'gone',
        if (!b.hasUpstream && !b.isProtected) 'no-upstream',
        if (b.ahead > 0) '↑${b.ahead}',
        if (b.behind > 0) '↓${b.behind}',
      ];
      final name = b.name.padRight(32);
      final when = b.relativeDate.padRight(16);
      stdout.writeln('$name $when ${tags.join(' ')}');
    }
  }
}
