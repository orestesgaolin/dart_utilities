import 'dart:io';

import 'package:args/command_runner.dart';

import '../chain/chain_service.dart';
import '../git/git_repo.dart';
import '../models.dart';
import '../storage/database.dart';

/// Lists tracked repos and their chains, with live sync status when run inside
/// a repository.
class ListCommand extends Command<void> {
  @override
  final name = 'list';

  @override
  final description = 'List tracked repos and chains (with status if inside a repo).';

  ListCommand() {
    argParser.addFlag('all',
        abbr: 'a',
        negatable: false,
        help: 'List every tracked repo, not just the current one.');
  }

  @override
  Future<void> run() async {
    final db = ChainDatabase.open();
    final service = ChainService(db);
    try {
      final all = argResults!['all'] as bool;
      final discovered = await service.registerRepo(Directory.current.path);

      if (!all && discovered != null) {
        await _printRepo(db, discovered.repo, discovered.git);
        return;
      }

      final repos = db.listRepos();
      if (repos.isEmpty) {
        stdout.writeln('No repositories tracked yet.');
        return;
      }
      for (final repo in repos) {
        await _printRepo(db, repo, null);
        stdout.writeln('');
      }
    } finally {
      db.close();
    }
  }

  Future<void> _printRepo(ChainDatabase db, Repo repo, GitRepo? git) async {
    final chains = db.listChains(repo.id);
    stdout.writeln('${repo.name}  (${chains.length} chain(s), target ${repo.defaultBranch})');
    if (chains.isEmpty) {
      stdout.writeln('  — no chains. Run `git_chain scan` to import from PRs.');
      return;
    }
    for (final chain in chains) {
      stdout.writeln('  • ${chain.name}');
      if (git != null) {
        final statuses = await git.chainStatus(chain);
        for (var i = 1; i < chain.branches.length; i++) {
          final b = chain.branches[i];
          final s = i - 1 < statuses.length ? statuses[i - 1] : null;
          final pr = b.prNumber != null ? '#${b.prNumber}' : '';
          final state = s == null
              ? ''
              : !s.exists
                  ? 'missing'
                  : s.behind > 0
                      ? '${s.behind} behind'
                      : 'in sync';
          stdout.writeln('      ${'  ' * (i - 1)}↳ ${b.branch}  $pr  $state');
        }
      } else {
        stdout.writeln('      ${chain.branches.map((b) => b.branch).join(' ← ')}');
      }
    }
  }
}
