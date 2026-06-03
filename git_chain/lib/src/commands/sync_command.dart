import 'dart:io';

import 'package:args/command_runner.dart';

import '../chain/chain_service.dart';
import '../chain/interactive_sync.dart';
import '../models.dart';
import '../storage/database.dart';

/// Synchronizes a chain in the current repo, cascading the latest target
/// branch through the stack and opening conflicts in the git mergetool.
class SyncCommand extends Command<void> {
  @override
  final name = 'sync';

  @override
  final description = 'Synchronize a chain to the latest target branch.';

  SyncCommand() {
    argParser.addOption('strategy',
        abbr: 's',
        allowed: ['rebase', 'merge'],
        defaultsTo: 'rebase',
        help: 'How to bring each branch up to its parent.');
  }

  @override
  Future<void> run() async {
    final db = ChainDatabase.open();
    final service = ChainService(db);
    try {
      final discovered = await service.registerRepo(Directory.current.path);
      if (discovered == null) {
        stderr.writeln('Not inside a git repository.');
        exitCode = 1;
        return;
      }
      final repo = discovered.repo;
      final git = discovered.git;

      var chains = db.listChains(repo.id);
      if (chains.isEmpty) {
        // Try detecting on the fly.
        for (final d in await service.detectChains(repo)) {
          service.saveDetectedChain(repo, d);
        }
        chains = db.listChains(repo.id);
      }
      if (chains.isEmpty) {
        stderr.writeln('No chains for ${repo.name}. Run `git_chain scan` first.');
        exitCode = 1;
        return;
      }

      final wanted = argResults!.rest.isEmpty ? null : argResults!.rest.first;
      Chain chain;
      if (wanted != null) {
        final match = chains.where((c) => c.name == wanted).toList();
        if (match.isEmpty) {
          stderr.writeln('No chain named "$wanted". Available:');
          for (final c in chains) {
            stderr.writeln('  - ${c.name}');
          }
          exitCode = 1;
          return;
        }
        chain = match.first;
      } else if (chains.length == 1) {
        chain = chains.first;
      } else {
        stderr.writeln('Multiple chains — specify one: git_chain sync <name>');
        for (final c in chains) {
          stderr.writeln('  - ${c.name}  (${c.branches.map((b) => b.branch).join(' ← ')})');
        }
        exitCode = 1;
        return;
      }

      // Refresh PR numbers before syncing.
      chain = await service.refreshChainPrs(repo, chain);

      final strategy = SyncStrategy.fromLabel(argResults!['strategy'] as String);
      final outcome = await runInteractiveSync(
        db: db,
        git: git,
        chain: chain,
        strategy: strategy,
      );
      if (outcome.status != 'ok') exitCode = 1;
    } finally {
      db.close();
    }
  }
}
