import 'dart:io';

import 'package:args/command_runner.dart';

import '../chain/chain_service.dart';
import '../git/github.dart';
import '../storage/database.dart';

/// Detects branch chains for the current repo from its open GitHub PRs and
/// stores any newly-found chains.
class ScanCommand extends Command<void> {
  @override
  final name = 'scan';

  @override
  final description =
      'Detect and import branch chains from open PRs in the current repo.';

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
      stdout.writeln('Repo: ${repo.name}  (target: ${repo.defaultBranch})');

      if (!await GitHub.isAvailable()) {
        stderr.writeln(
            'GitHub CLI (`gh`) not found — install it to auto-detect chains from PRs.');
        exitCode = 1;
        return;
      }

      final detected = await service.detectChains(repo);
      if (detected.isEmpty) {
        stdout.writeln('No stacked chains found in open PRs.');
        return;
      }

      var added = 0;
      for (final d in detected) {
        final saved = service.saveDetectedChain(repo, d);
        final mark = saved == null ? '= existing' : '+ imported';
        stdout.writeln(
            '$mark  ${d.branches.map((b) => b.branch).join(' ← ')}');
        if (saved != null) added++;
      }
      stdout.writeln('\n$added new chain(s) imported.');
    } finally {
      db.close();
    }
  }
}
