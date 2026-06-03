import 'dart:io';

import '../git/git_repo.dart';
import '../models.dart';
import '../storage/database.dart';
import 'sync_engine.dart';

/// Runs a chain sync in the foreground terminal, launching `git mergetool` for
/// conflicts and recording the run in [db].
///
/// Must be called when no TUI is occupying the terminal, so the merge tool can
/// take over stdin/stdout.
Future<SyncOutcome> runInteractiveSync({
  required ChainDatabase db,
  required GitRepo git,
  required Chain chain,
  required SyncStrategy strategy,
}) async {
  stdout.writeln('');
  stdout.writeln('━━ Syncing chain "${chain.name}" (${strategy.label}) ━━');
  stdout.writeln('   ${chain.branches.map((b) => b.branch).join(' ← ')}');
  stdout.writeln('');

  // A dirty tree blocks rebase/merge. Offer to stash under an explicit label
  // and restore once the sync finishes.
  String? stashLabel;
  if (await git.isDirty()) {
    stdout.write('Working tree is dirty. Stash changes and restore after sync? [y/n] ');
    final answer = stdin.readLineSync()?.trim().toLowerCase();
    if (answer == 'y' || answer == 'yes') {
      stashLabel = GitRepo.stashLabel('pre-sync ${chain.name}');
      final pushed = await git.stashPush(stashLabel);
      if (!pushed.ok) {
        stdout.writeln('✗ stash failed: ${pushed.stderr.trim()}');
        return SyncOutcome(
          status: 'failed',
          steps: const [],
          startedAt: DateTime.now(),
          finishedAt: DateTime.now(),
        );
      }
      stdout.writeln('Stashed as "$stashLabel".');
    } else {
      stdout.writeln('Aborted — commit or stash your changes first.');
      return SyncOutcome(
        status: 'aborted',
        steps: const [],
        startedAt: DateTime.now(),
        finishedAt: DateTime.now(),
      );
    }
  }

  final engine = SyncEngine(
    repo: git,
    log: stdout.writeln,
    resolveConflict: (branch, files) async {
      stdout.writeln('');
      stdout.writeln('⚠ Conflicts while syncing "$branch":');
      for (final f in files) {
        stdout.writeln('    $f');
      }
      stdout.writeln('→ Opening git mergetool…');
      await git.runInteractive(['mergetool']);

      final remaining = await git.conflictedFiles();
      if (remaining.isEmpty) return true;

      stdout.writeln('Still unresolved: ${remaining.join(', ')}');
      stdout.write('Continue with these resolved as-is (c) or abort (a)? [c/a] ');
      final answer = stdin.readLineSync()?.trim().toLowerCase();
      return answer == 'c';
    },
  );

  final outcome = await engine.run(chain, strategy);

  // Restore stashed changes (the engine returns to the original branch).
  if (stashLabel != null) {
    final popError = await git.stashPopByMessage(stashLabel);
    if (popError == null) {
      stdout.writeln('Restored stashed changes.');
    } else {
      stdout.writeln('⚠ Stash "$stashLabel" kept — restore manually ($popError).');
    }
  }

  db.recordSyncRun(
    chainId: chain.id,
    strategy: strategy,
    status: outcome.status,
    summary: outcome.summary,
    startedAt: outcome.startedAt,
    finishedAt: outcome.finishedAt,
    steps: outcome.steps,
  );

  stdout.writeln('');
  stdout.writeln('━━ Sync ${outcome.status.toUpperCase()} — ${outcome.summary} ━━');
  return outcome;
}
