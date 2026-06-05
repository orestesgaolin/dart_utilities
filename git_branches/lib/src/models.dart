/// Data models for git_branches.
library;

/// Per-branch batch selection: cycle none → delete → push → none.
enum MarkState { none, delete, push }

/// Ordering of the branch list.
enum SortOrder {
  /// Stalest first (oldest last activity at the top) — the default, since the
  /// tool is about finding cleanup candidates.
  activityAsc,

  /// Most recently active first.
  activityDesc,

  /// Alphabetical by branch name.
  name;

  String get label => switch (this) {
        SortOrder.activityAsc => 'stalest first',
        SortOrder.activityDesc => 'recent first',
        SortOrder.name => 'name',
      };

  SortOrder get next => switch (this) {
        SortOrder.activityAsc => SortOrder.activityDesc,
        SortOrder.activityDesc => SortOrder.name,
        SortOrder.name => SortOrder.activityAsc,
      };
}

/// Which branches to show.
enum BranchFilter {
  all,
  merged,
  unmerged;

  String get label => switch (this) {
        BranchFilter.all => 'all',
        BranchFilter.merged => 'merged',
        BranchFilter.unmerged => 'unmerged',
      };

  BranchFilter get next => switch (this) {
        BranchFilter.all => BranchFilter.merged,
        BranchFilter.merged => BranchFilter.unmerged,
        BranchFilter.unmerged => BranchFilter.all,
      };
}

/// Snapshot of a local branch and its relationship to the default branch and
/// its upstream.
class BranchInfo {
  BranchInfo({
    required this.name,
    required this.isCurrent,
    required this.isDefault,
    required this.isMerged,
    required this.lastActivity,
    required this.relativeDate,
    required this.subject,
    required this.ahead,
    required this.behind,
    required this.upstreamGone,
    this.isSquashMerged = false,
    this.upstream,
  });

  final String name;
  final bool isCurrent;

  /// Whether this is the repository's default/target branch.
  final bool isDefault;

  /// Whether the branch is reachability-merged into the default branch
  /// (i.e. `git branch --merged` / safe for `git branch -d`).
  final bool isMerged;

  /// Whether the branch's changes are already on the default branch via a
  /// squash (or rebase) merge — its work is upstream, but git's reachability
  /// check doesn't see it, so deletion still needs `-D`.
  final bool isSquashMerged;

  final DateTime lastActivity;

  /// Git's human-readable relative date (e.g. "3 weeks ago").
  final String relativeDate;
  final String subject;

  /// Remote tracking branch, if configured.
  final String? upstream;

  /// Commits ahead/behind the upstream.
  final int ahead;
  final int behind;

  /// Upstream was configured but no longer exists on the remote.
  final bool upstreamGone;

  /// Effectively merged by any means (reachability or squash/rebase).
  bool get isEffectivelyMerged => isMerged || isSquashMerged;

  bool get hasUpstream => upstream != null && upstream!.isNotEmpty;

  /// Local commits not yet on the remote (or no upstream at all).
  bool get needsPush => !hasUpstream || ahead > 0;

  /// Cannot be deleted from the list.
  bool get isProtected => isCurrent || isDefault;
}
