import '../git/git_repo.dart';
import '../models.dart';

/// Outcome of a full sync run.
class SyncOutcome {
  SyncOutcome({
    required this.status,
    required this.steps,
    required this.startedAt,
    required this.finishedAt,
  });

  /// `ok`, `conflict`, `aborted`, or `failed`.
  final String status;
  final List<SyncStepResult> steps;
  final DateTime startedAt;
  final DateTime finishedAt;

  String get summary {
    final synced = steps.where((s) => s.status == StepStatus.synced).length;
    final upToDate = steps.where((s) => s.status == StepStatus.upToDate).length;
    final conflicts = steps.where((s) => s.status == StepStatus.conflict).length;
    return '$synced synced, $upToDate up-to-date, $conflicts conflicts';
  }
}

/// Resolves a conflict during a sync step. Returns true once the working tree
/// is conflict-free and the operation may continue; false to abort the step.
typedef ConflictResolver = Future<bool> Function(
    String branch, List<String> conflictedFiles);

/// Reports human-readable progress during a sync.
typedef SyncLogger = void Function(String message);

/// Cascades the latest target branch through a chain of stacked branches.
///
/// For `main <- feat/1 <- feat/2`, a rebase sync rebases `feat/1` onto the
/// freshly-updated `main`, then `feat/2` onto the updated `feat/1`. A merge
/// sync merges each parent into its child instead.
///
/// Interactive git commands (mergetool) inherit the terminal, so the engine
/// must run with the TUI suspended.
class SyncEngine {
  SyncEngine({
    required this.repo,
    required this.log,
    required this.resolveConflict,
  });

  final GitRepo repo;
  final SyncLogger log;
  final ConflictResolver resolveConflict;

  /// Runs the full chain sync and returns its outcome.
  Future<SyncOutcome> run(Chain chain, SyncStrategy strategy) async {
    final startedAt = DateTime.now();
    final steps = <SyncStepResult>[];

    final originalBranch = await repo.currentBranch();

    if (await repo.isDirty()) {
      log('✗ Working tree has uncommitted changes — commit or stash first.');
      return SyncOutcome(
        status: 'failed',
        steps: steps,
        startedAt: startedAt,
        finishedAt: DateTime.now(),
      );
    }

    log('⟳ Fetching all remotes…');
    final fetch = await repo.fetchAll();
    if (!fetch.ok) {
      log('  (fetch failed: ${fetch.stderr.trim()})');
    }

    // Update the target branch to its upstream first.
    final target = chain.targetBranch;
    log('⟳ Updating target $target …');
    final ffError = await repo.fastForwardToUpstream(target);
    if (ffError != null) {
      log('  ! could not fast-forward $target: $ffError');
    }

    var aborted = false;
    for (var i = 1; i < chain.branches.length && !aborted; i++) {
      final branch = chain.branches[i].branch;
      final parent = chain.branches[i - 1].branch;

      if (!await repo.branchExists(branch)) {
        log('• $branch — missing locally, skipped');
        steps.add(SyncStepResult(
            branch: branch, parent: parent, status: StepStatus.skipped,
            detail: 'branch not found locally'));
        continue;
      }

      final (_, behind) = await repo.aheadBehind(branch, parent);
      if (behind == 0) {
        log('✓ $branch — already up to date with $parent');
        steps.add(SyncStepResult(
            branch: branch, parent: parent, status: StepStatus.upToDate));
        continue;
      }

      log('⟳ ${strategy.label} $branch onto $parent ($behind behind)…');
      final result = await _syncBranch(branch, parent, strategy);
      steps.add(result);
      if (result.status == StepStatus.synced) {
        log('✓ $branch — ${strategy.label}d onto $parent');
      } else if (result.status == StepStatus.conflict) {
        log('⚠ $branch — unresolved conflicts, stopping chain');
        aborted = true;
      } else if (result.status == StepStatus.aborted) {
        log('✗ $branch — aborted by user, stopping chain');
        aborted = true;
      } else if (result.status == StepStatus.failed) {
        log('✗ $branch — ${result.detail ?? 'failed'}, stopping chain');
        aborted = true;
      }
    }

    // Return to where the user started, if possible.
    if (await repo.branchExists(originalBranch)) {
      await repo.checkout(originalBranch);
    }

    final hadConflict = steps.any((s) => s.status == StepStatus.conflict);
    final hadAbort = steps.any((s) => s.status == StepStatus.aborted);
    final hadFail = steps.any((s) => s.status == StepStatus.failed);
    final status = hadAbort
        ? 'aborted'
        : hadConflict
            ? 'conflict'
            : hadFail
                ? 'failed'
                : 'ok';

    return SyncOutcome(
      status: status,
      steps: steps,
      startedAt: startedAt,
      finishedAt: DateTime.now(),
    );
  }

  Future<SyncStepResult> _syncBranch(
      String branch, String parent, SyncStrategy strategy) async {
    final checkout = await repo.checkout(branch);
    if (!checkout.ok) {
      return SyncStepResult(
          branch: branch, parent: parent, status: StepStatus.failed,
          detail: 'checkout failed: ${checkout.stderr.trim()}');
    }

    final GitResult op = strategy == SyncStrategy.rebase
        ? await repo.run(['rebase', parent])
        : await repo.run(['merge', '--no-edit', parent]);

    if (op.ok) {
      return SyncStepResult(
          branch: branch, parent: parent, status: StepStatus.synced);
    }

    // Non-zero exit: either a conflict (resolvable) or a hard failure.
    var conflicts = await repo.conflictedFiles();
    if (conflicts.isEmpty) {
      // Not a conflict — abort whatever operation is in flight and report.
      await _abortOperation(strategy);
      return SyncStepResult(
          branch: branch, parent: parent, status: StepStatus.failed,
          detail: op.stderr.trim().isEmpty ? op.stdout.trim() : op.stderr.trim());
    }

    // Resolve conflicts, possibly across several rebase steps.
    final allConflicts = <String>{...conflicts};
    while (conflicts.isNotEmpty) {
      final resolved = await resolveConflict(branch, conflicts);
      if (!resolved) {
        await _abortOperation(strategy);
        return SyncStepResult(
            branch: branch, parent: parent, status: StepStatus.aborted,
            detail: 'user aborted', conflictedFiles: allConflicts.toList());
      }

      // Stage resolved files and continue the operation.
      final cont = await _continueOperation(strategy);
      if (cont == _ContinueResult.done) {
        return SyncStepResult(
            branch: branch, parent: parent, status: StepStatus.synced,
            conflictedFiles: allConflicts.toList());
      }
      if (cont == _ContinueResult.failed) {
        return SyncStepResult(
            branch: branch, parent: parent, status: StepStatus.conflict,
            detail: 'could not continue ${strategy.label}',
            conflictedFiles: allConflicts.toList());
      }
      // More conflicts surfaced (next commit in the rebase).
      conflicts = await repo.conflictedFiles();
      allConflicts.addAll(conflicts);
    }

    return SyncStepResult(
        branch: branch, parent: parent, status: StepStatus.synced,
        conflictedFiles: allConflicts.toList());
  }

  Future<void> _abortOperation(SyncStrategy strategy) async {
    if (strategy == SyncStrategy.rebase) {
      await repo.run(['rebase', '--abort']);
    } else {
      await repo.run(['merge', '--abort']);
    }
  }

  Future<_ContinueResult> _continueOperation(SyncStrategy strategy) async {
    // Suppress the commit-message editor so the operation doesn't hang.
    final env = {'GIT_EDITOR': 'true', 'GIT_SEQUENCE_EDITOR': 'true'};
    await repo.run(['add', '-A']);
    if (strategy == SyncStrategy.rebase) {
      final result = await repo.run(['rebase', '--continue'], environment: env);
      if (result.ok) return _ContinueResult.done;
      // Still mid-rebase with more conflicts?
      final conflicts = await repo.conflictedFiles();
      return conflicts.isNotEmpty
          ? _ContinueResult.moreConflicts
          : _ContinueResult.failed;
    } else {
      final result = await repo.run(['commit', '--no-edit'], environment: env);
      return result.ok ? _ContinueResult.done : _ContinueResult.failed;
    }
  }
}

enum _ContinueResult { done, moreConflicts, failed }
