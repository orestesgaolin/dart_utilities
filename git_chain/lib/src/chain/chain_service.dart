import 'package:path/path.dart' as p;

import '../git/git_repo.dart';
import '../git/github.dart';
import '../models.dart';
import '../storage/database.dart';
import 'chain_detector.dart';

/// Facade that wires together git, GitHub, detection, and persistence.
class ChainService {
  ChainService(this.db);

  final ChainDatabase db;

  /// Discovers the git repo enclosing [dir], registers/refreshes it in the
  /// database, and returns the [Repo] together with its [GitRepo]. Returns null
  /// if [dir] is not inside a git repository.
  Future<({Repo repo, GitRepo git})?> registerRepo(String dir) async {
    final git = await GitRepo.discover(dir);
    if (git == null) return null;
    final defaultBranch = await git.defaultBranch();
    final remoteUrl = await git.remoteUrl();
    final slug = await git.ownerRepoSlug();
    final name = slug ?? p.basename(git.root);
    final repo = db.upsertRepo(
      path: git.root,
      name: name,
      defaultBranch: defaultBranch,
      remoteUrl: remoteUrl,
    );
    return (repo: repo, git: git);
  }

  /// Fetches open PRs for [repo] (empty if `gh` is unavailable).
  Future<List<PullRequest>> fetchPullRequests(Repo repo) =>
      GitHub(repo.path).openPullRequests();

  /// Suggests chains for [repo] from its open PRs.
  Future<List<DetectedChain>> detectChains(Repo repo) async {
    final prs = await fetchPullRequests(repo);
    return ChainDetector.fromPullRequests(prs, repo.defaultBranch);
  }

  /// Persists a detected chain, skipping it if an identical branch list already
  /// exists for the repo. Returns the stored chain, or null if a duplicate.
  Chain? saveDetectedChain(Repo repo, DetectedChain detected) {
    final existing = db.listChains(repo.id);
    final newBranches = detected.branches.map((b) => b.branch).toList();
    for (final chain in existing) {
      final branches = chain.branches.map((b) => b.branch).toList();
      if (_listEquals(branches, newBranches)) return null;
    }
    return db.createChain(
      repoId: repo.id,
      name: detected.suggestedName,
      targetBranch: detected.targetBranch,
      branches: detected.branches,
    );
  }

  /// Re-attaches current PR numbers to a stored chain's branches and persists.
  Future<Chain> refreshChainPrs(Repo repo, Chain chain) async {
    final prs = await fetchPullRequests(repo);
    final annotated = ChainDetector.annotateWithPrs(chain.branches, prs);
    db.updateChainBranches(chain.id, annotated);
    return db.getChain(chain.id)!;
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
