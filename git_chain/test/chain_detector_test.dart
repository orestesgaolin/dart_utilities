import 'package:git_chain/git_chain.dart';
import 'package:test/test.dart';

PullRequest pr(int number, String base, String head) => PullRequest(
      number: number,
      title: 'PR $number',
      headRef: head,
      baseRef: base,
      state: 'OPEN',
      url: 'https://example/$number',
      isDraft: false,
    );

void main() {
  group('ChainDetector.fromPullRequests', () {
    test('reconstructs a linear stack rooted at the default branch', () {
      final prs = [
        pr(1, 'main', 'feat/1'),
        pr(2, 'feat/1', 'feat/2'),
        pr(3, 'feat/2', 'feat/3'),
      ];
      final chains = ChainDetector.fromPullRequests(prs, 'main');
      expect(chains, hasLength(1));
      final branches = chains.single.branches.map((b) => b.branch).toList();
      expect(branches, ['main', 'feat/1', 'feat/2', 'feat/3']);
      expect(chains.single.targetBranch, 'main');
      expect(chains.single.suggestedName, 'feat/3');
      // PR numbers attached to the right branches.
      expect(chains.single.branches[1].prNumber, 1);
      expect(chains.single.branches[3].prNumber, 3);
    });

    test('forks produce one chain per leaf path', () {
      final prs = [
        pr(1, 'main', 'feat/1'),
        pr(2, 'feat/1', 'feat/2a'),
        pr(3, 'feat/1', 'feat/2b'),
      ];
      final chains = ChainDetector.fromPullRequests(prs, 'main');
      final tips = chains.map((c) => c.branches.last.branch).toSet();
      expect(chains, hasLength(2));
      expect(tips, {'feat/2a', 'feat/2b'});
    });

    test('a chain rooted at a non-default base is still detected', () {
      // release/1 is never the head of a PR, so it is a root.
      final prs = [
        pr(1, 'release/1', 'hotfix/a'),
        pr(2, 'hotfix/a', 'hotfix/b'),
      ];
      final chains = ChainDetector.fromPullRequests(prs, 'main');
      expect(chains, hasLength(1));
      expect(chains.single.targetBranch, 'release/1');
      expect(chains.single.branches.map((b) => b.branch),
          ['release/1', 'hotfix/a', 'hotfix/b']);
    });

    test('skips single-branch chains by default but keeps them on request', () {
      final prs = [pr(1, 'main', 'feat/1')]; // only one stacked branch
      expect(ChainDetector.fromPullRequests(prs, 'main'), isEmpty);
      final kept = ChainDetector.fromPullRequests(prs, 'main', minStackSize: 1);
      expect(kept, hasLength(1));
      expect(kept.single.branches.map((b) => b.branch), ['main', 'feat/1']);
    });

    test('ignores closed PRs and returns empty when nothing is open', () {
      final closed = PullRequest(
        number: 9,
        title: 'old',
        headRef: 'feat/x',
        baseRef: 'main',
        state: 'CLOSED',
        url: '',
        isDraft: false,
      );
      expect(ChainDetector.fromPullRequests([closed], 'main'), isEmpty);
    });
  });

  group('ChainDetector.annotateWithPrs', () {
    test('matches PR numbers onto manual branches by head name', () {
      final branches = [
        ChainBranch(branch: 'main', position: 0),
        ChainBranch(branch: 'feat/1', position: 1),
        ChainBranch(branch: 'feat/2', position: 2),
      ];
      final annotated = ChainDetector.annotateWithPrs(branches, [
        pr(7, 'main', 'feat/1'),
        pr(8, 'feat/1', 'feat/2'),
      ]);
      expect(annotated[1].prNumber, 7);
      expect(annotated[2].prNumber, 8);
      expect(annotated[0].prNumber, isNull);
    });
  });
}
