import '../models.dart';

/// A chain inferred from PR metadata (not yet persisted).
class DetectedChain {
  DetectedChain({
    required this.targetBranch,
    required this.branches,
  });

  final String targetBranch;

  /// Ordered branches including the target at index 0.
  final List<ChainBranch> branches;

  /// Suggested chain name: the tip branch.
  String get suggestedName =>
      branches.length > 1 ? branches.last.branch : targetBranch;
}

/// Reconstructs stacked branch chains from open pull requests.
///
/// Each PR contributes an edge `baseRef -> headRef`. Chains are the maximal
/// root-to-leaf paths through that graph, where roots are bases that are not
/// themselves the head of another PR (the [defaultBranch] is always a root).
class ChainDetector {
  /// Builds chains from [prs]. Forks produce one chain per leaf path.
  ///
  /// [minStackSize] is the minimum number of stacked branches (excluding the
  /// target) a chain must have to be returned. It defaults to 2 so trivial
  /// single-PR "chains" (`main ← feat/1`) are skipped.
  static List<DetectedChain> fromPullRequests(
    List<PullRequest> prs,
    String defaultBranch, {
    int minStackSize = 2,
  }) {
    final open = prs.where((pr) => pr.state == 'OPEN').toList();
    if (open.isEmpty) return [];

    // base -> list of (head, prNumber)
    final children = <String, List<PullRequest>>{};
    final heads = <String>{};
    for (final pr in open) {
      children.putIfAbsent(pr.baseRef, () => []).add(pr);
      heads.add(pr.headRef);
    }

    final roots = <String>{defaultBranch};
    for (final base in children.keys) {
      if (!heads.contains(base)) roots.add(base);
    }

    final chains = <DetectedChain>[];
    for (final root in roots) {
      if (!children.containsKey(root)) continue;
      _walk(root, root, [ChainBranch(branch: root, position: 0)], children,
          chains, <String>{root});
    }
    // Drop chains shorter than the requested minimum stack size.
    return chains
        .where((c) => c.branches.length - 1 >= minStackSize)
        .toList();
  }

  static void _walk(
    String target,
    String current,
    List<ChainBranch> path,
    Map<String, List<PullRequest>> children,
    List<DetectedChain> out,
    Set<String> visited,
  ) {
    final next = children[current];
    if (next == null || next.isEmpty) {
      if (path.length > 1) {
        out.add(DetectedChain(targetBranch: target, branches: List.of(path)));
      }
      return;
    }
    for (final pr in next) {
      if (visited.contains(pr.headRef)) continue; // guard against cycles
      final branch = ChainBranch(
        branch: pr.headRef,
        position: path.length,
        prNumber: pr.number,
      );
      _walk(
        target,
        pr.headRef,
        [...path, branch],
        children,
        out,
        {...visited, pr.headRef},
      );
    }
  }

  /// Attaches PR numbers from [prs] to the branches of an existing/manual
  /// chain, matching on head branch name. Returns a new branch list.
  static List<ChainBranch> annotateWithPrs(
    List<ChainBranch> branches,
    List<PullRequest> prs,
  ) {
    final byHead = {for (final pr in prs) pr.headRef: pr.number};
    return [
      for (final b in branches)
        ChainBranch(
          branch: b.branch,
          position: b.position,
          prNumber: byHead[b.branch] ?? b.prNumber,
        ),
    ];
  }
}
