import 'dart:io';

import 'package:git_chain/git_chain.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A branch that has merged its parent several times (so it contains merge
/// commits) must still rebase cleanly: git drops the merges and replays only
/// the real commits — which is exactly what we want for a stacked chain.
void main() {
  late Directory tmp;
  late GitRepo git;

  Future<void> sh(List<String> args) async {
    final r = await Process.run('git', args, workingDirectory: tmp.path,
        environment: const {'GIT_TERMINAL_PROMPT': '0', 'GIT_EDITOR': 'true'});
    if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
  }

  Future<void> commit(String file, String body, String msg) async {
    File(p.join(tmp.path, file)).writeAsStringSync('$body\n');
    await sh(['add', file]);
    await sh(['commit', '-q', '-m', msg]);
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('git_chain_merges');
    git = GitRepo(tmp.path);
    await sh(['init', '-q', '-b', 'main']);
    await sh(['config', 'user.email', 't@e.com']);
    await sh(['config', 'user.name', 'T']);
    await commit('base.txt', 'base', 'base');

    // Feature branch touches its own file (no conflicts with main's files).
    await sh(['checkout', '-q', '-b', 'feat']);
    await commit('feat.txt', 'feat work', 'feat: work');

    // main advances, then feat merges main in twice (creating merge commits).
    await sh(['checkout', '-q', 'main']);
    await commit('main1.txt', 'one', 'main: one');
    await sh(['checkout', '-q', 'feat']);
    await sh(['merge', '--no-edit', 'main']);
    await sh(['checkout', '-q', 'main']);
    await commit('main2.txt', 'two', 'main: two');
    await sh(['checkout', '-q', 'feat']);
    await sh(['merge', '--no-edit', 'main']);

    // main advances once more so feat is behind and needs a sync.
    await sh(['checkout', '-q', 'main']);
    await commit('main3.txt', 'three', 'main: three');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('rebasing a branch with merge commits succeeds and drops the merges',
      () async {
    // Sanity: the branch really does contain merge commits before the rebase.
    final before = await git.commitsBetween('main', 'feat');
    final mergesBefore = await Process.run(
        'git', ['log', '--merges', '--oneline', 'main..feat'],
        workingDirectory: tmp.path);
    expect((mergesBefore.stdout as String).trim(), isNotEmpty,
        reason: 'precondition: feat has merge commits');
    expect(before.map((c) => c.subject), contains('feat: work'));

    final chain = Chain(
      id: 1,
      repoId: 1,
      name: 'feat',
      targetBranch: 'main',
      branches: [
        ChainBranch(branch: 'main', position: 0),
        ChainBranch(branch: 'feat', position: 1),
      ],
    );

    var resolverCalled = false;
    final engine = SyncEngine(
      repo: git,
      log: (_) {},
      resolveConflict: (_, _) async {
        resolverCalled = true;
        return false;
      },
    );

    final outcome = await engine.run(chain, SyncStrategy.rebase);

    expect(resolverCalled, isFalse, reason: 'no conflicts expected');
    expect(outcome.status, 'ok');

    // After the rebase, feat sits directly on main with no merge commits and
    // the real work preserved.
    final mergesAfter = await Process.run(
        'git', ['log', '--merges', '--oneline', 'main..feat'],
        workingDirectory: tmp.path);
    expect((mergesAfter.stdout as String).trim(), isEmpty,
        reason: 'merge commits dropped');
    expect(await git.branchExists('feat'), isTrue);
    // The real work is preserved on the feat branch (we end up back on main).
    expect((await git.run(['cat-file', '-e', 'feat:feat.txt'])).ok, isTrue);
    // main is now a direct ancestor (linear).
    final ancestor = await git.run(
        ['merge-base', '--is-ancestor', 'main', 'feat']);
    expect(ancestor.ok, isTrue);
  });
}
