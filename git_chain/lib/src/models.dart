/// Data models shared across git_chain.
library;

/// Strategy used when synchronizing a chain.
enum SyncStrategy {
  /// Rebase each branch onto its (freshly updated) parent.
  rebase,

  /// Merge the (freshly updated) parent into each branch.
  merge;

  String get label => switch (this) {
        SyncStrategy.rebase => 'rebase',
        SyncStrategy.merge => 'merge',
      };

  static SyncStrategy fromLabel(String value) => switch (value) {
        'merge' => SyncStrategy.merge,
        _ => SyncStrategy.rebase,
      };
}

/// A repository that git_chain knows about.
class Repo {
  Repo({
    required this.id,
    required this.path,
    required this.name,
    required this.defaultBranch,
    this.remoteUrl,
    this.lastOpenedAt,
  });

  final int id;

  /// Canonical filesystem path to the repository root.
  final String path;

  /// Short display name (usually `owner/repo` or the folder name).
  final String name;

  /// Default/target branch of the repo (e.g. `main`).
  final String defaultBranch;

  /// Origin remote URL, if known.
  final String? remoteUrl;

  final DateTime? lastOpenedAt;
}

/// A stacked chain of branches, ordered from the target branch outward.
///
/// `branches[0]` is always the [targetBranch]; subsequent entries each build on
/// the previous one (`main <- feat/1 <- feat/2`).
class Chain {
  Chain({
    required this.id,
    required this.repoId,
    required this.name,
    required this.targetBranch,
    required this.branches,
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final int repoId;
  final String name;
  final String targetBranch;

  /// Ordered branches, including the target branch at index 0.
  final List<ChainBranch> branches;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Branches excluding the target (the actual feature stack).
  List<ChainBranch> get stack => branches.skip(1).toList();

  /// The tip (top-most) branch of the chain, or the target if empty.
  String get tip => branches.isEmpty ? targetBranch : branches.last.branch;
}

/// One branch within a [Chain].
class ChainBranch {
  ChainBranch({
    required this.branch,
    required this.position,
    this.prNumber,
  });

  final String branch;

  /// 0-based position in the chain (0 == target branch).
  final int position;

  /// Associated GitHub PR number, if detected.
  final int? prNumber;
}

/// A GitHub pull request, as reported by `gh`.
class PullRequest {
  PullRequest({
    required this.number,
    required this.title,
    required this.headRef,
    required this.baseRef,
    required this.state,
    required this.url,
    required this.isDraft,
    this.mergeStateStatus,
    this.assignees = const [],
  });

  final int number;
  final String title;

  /// Source branch (the branch the PR is from).
  final String headRef;

  /// Target branch (the branch the PR merges into).
  final String baseRef;

  /// `OPEN`, `MERGED`, `CLOSED`.
  final String state;
  final String url;
  final bool isDraft;

  /// `CLEAN`, `DIRTY`, `BLOCKED`, `BEHIND`, `UNKNOWN`, …
  final String? mergeStateStatus;

  /// GitHub logins of the PR's assignees.
  final List<String> assignees;

  factory PullRequest.fromJson(Map<String, dynamic> json) => PullRequest(
        number: json['number'] as int,
        title: (json['title'] as String?) ?? '',
        headRef: (json['headRefName'] as String?) ?? '',
        baseRef: (json['baseRefName'] as String?) ?? '',
        state: (json['state'] as String?) ?? 'OPEN',
        url: (json['url'] as String?) ?? '',
        isDraft: (json['isDraft'] as bool?) ?? false,
        mergeStateStatus: json['mergeStateStatus'] as String?,
        assignees: ((json['assignees'] as List<dynamic>?) ?? [])
            .cast<Map<String, dynamic>>()
            .map((a) => (a['login'] as String?) ?? '')
            .where((s) => s.isNotEmpty)
            .toList(),
      );
}

/// Live git status of a branch relative to its parent in the chain.
class BranchStatus {
  BranchStatus({
    required this.branch,
    required this.exists,
    required this.ahead,
    required this.behind,
    this.lastCommitSubject,
    this.upstreamAhead,
    this.upstreamBehind,
  });

  final String branch;

  /// Whether the branch exists locally.
  final bool exists;

  /// Commits this branch is ahead of its parent.
  final int ahead;

  /// Commits this branch is behind its parent (needs sync when > 0).
  final int behind;

  final String? lastCommitSubject;

  /// Commits ahead of the remote tracking branch (needs push when > 0).
  final int? upstreamAhead;

  /// Commits behind the remote tracking branch.
  final int? upstreamBehind;

  bool get needsSync => behind > 0;
  bool get needsPush => (upstreamAhead ?? 0) > 0;
}

/// Outcome of a single branch sync step.
enum StepStatus { synced, upToDate, conflict, aborted, skipped, failed }

/// Result of one branch's sync within a run.
class SyncStepResult {
  SyncStepResult({
    required this.branch,
    required this.parent,
    required this.status,
    this.detail,
    this.conflictedFiles = const [],
  });

  final String branch;
  final String parent;
  final StepStatus status;
  final String? detail;
  final List<String> conflictedFiles;
}

/// A persisted record of a completed sync run.
class SyncRun {
  SyncRun({
    required this.id,
    required this.chainId,
    required this.strategy,
    required this.status,
    required this.summary,
    required this.startedAt,
    this.finishedAt,
  });

  final int id;
  final int chainId;
  final SyncStrategy strategy;

  /// Overall status string, e.g. `ok`, `conflict`, `failed`, `aborted`.
  final String status;
  final String summary;
  final DateTime startedAt;
  final DateTime? finishedAt;
}
