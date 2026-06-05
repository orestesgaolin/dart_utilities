import 'dart:io';

import '../git/git_repo.dart';
import '../models.dart';
import '../storage/database.dart';
import 'sync_engine.dart';

/// Runs a chain sync in the foreground terminal, launching `git mergetool` for
/// conflicts and recording the run in [db].
///
/// Two modes:
/// - **CLI** (`canPrompt: true`, the default): reads stdin to ask about
///   stashing and post-mergetool continuation.
/// - **TUI handoff** (`canPrompt: false`): stdin is unusable for synchronous
///   reads after a nocterm session, so no prompts are issued. The caller passes
///   the already-made decisions via [preStashedLabel] / [allowDirty], and
///   conflict continuation is detected automatically after the merge tool runs.
Future<SyncOutcome> runInteractiveSync({
  required ChainDatabase db,
  required GitRepo git,
  required Chain chain,
  required SyncStrategy strategy,
  bool canPrompt = true,
  String? preStashedLabel,
  bool allowDirty = false,
}) async {
  stdout.writeln('');
  stdout.writeln('━━ Syncing chain "${chain.name}" (${strategy.label}) ━━');
  stdout.writeln('   ${chain.branches.map((b) => b.branch).join(' ← ')}');
  stdout.writeln('');

  // Resolve how to handle a dirty tree.
  String? stashLabel = preStashedLabel; // popped at the end if non-null
  if (preStashedLabel != null) {
    stdout.writeln('Using changes stashed as "$preStashedLabel".');
  } else if (!allowDirty && await git.isDirty()) {
    if (canPrompt) {
      stdout.write('Working tree is dirty. Stash changes and restore after sync? [y/n] ');
      final answer = stdin.readLineSync()?.trim().toLowerCase();
      if (answer != 'y' && answer != 'yes') {
        stdout.writeln('Aborted — commit or stash your changes first.');
        return _quick('aborted');
      }
    }
    stashLabel = GitRepo.stashLabel('pre-sync ${chain.name}');
    final pushed = await git.stashPush(stashLabel);
    if (!pushed.ok) {
      stdout.writeln('✗ stash failed: ${pushed.stderr.trim()}');
      return _quick('failed');
    }
    stdout.writeln('Stashed as "$stashLabel".');
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
      if (!canPrompt) {
        // Can't ask; the safe default is to abort the (already clean-on-abort)
        // operation rather than commit half-resolved files.
        stdout.writeln('Aborting this branch — resolve and re-run `git_chain sync`.');
        return false;
      }
      stdout.write('Continue with these resolved as-is (c) or abort (a)? [c/a] ');
      final answer = stdin.readLineSync()?.trim().toLowerCase();
      return answer == 'c';
    },
  );

  final outcome = await engine.run(chain, strategy, allowDirty: allowDirty);

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

SyncOutcome _quick(String status) => SyncOutcome(
      status: status,
      steps: const [],
      startedAt: DateTime.now(),
      finishedAt: DateTime.now(),
    );
