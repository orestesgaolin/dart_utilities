import 'dart:io';

import 'package:git_branches/git_branches.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late GitRepo git;

  Future<void> sh(List<String> args) async {
    final r = await Process.run('git', args, workingDirectory: tmp.path);
    if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
  }

  Future<void> commit(String file, String msg) async {
    File(p.join(tmp.path, file)).writeAsStringSync('$msg\n');
    await sh(['add', file]);
    await sh(['commit', '-q', '-m', msg]);
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('git_branches_test');
    git = GitRepo(tmp.path);
    await sh(['init', '-q', '-b', 'main']);
    await sh(['config', 'user.email', 't@e.com']);
    await sh(['config', 'user.name', 'T']);
    await commit('a.txt', 'base');

    // Merged branch.
    await sh(['checkout', '-q', '-b', 'feature/done']);
    await commit('done.txt', 'done work');
    await sh(['checkout', '-q', 'main']);
    await sh(['merge', '-q', '--no-ff', '-m', 'merge done', 'feature/done']);

    // Unmerged branch.
    await sh(['checkout', '-q', '-b', 'feature/wip']);
    await commit('wip.txt', 'wip work');
    await sh(['checkout', '-q', 'main']);

    // Squash-merged branch: its changes land on main as one new commit with no
    // ancestry link, so `git branch --merged` will NOT see it.
    await sh(['checkout', '-q', '-b', 'feature/squashed']);
    await commit('squashed.txt', 'squashed feature');
    await sh(['checkout', '-q', 'main']);
    await sh(['merge', '-q', '--squash', 'feature/squashed']);
    await sh(['commit', '-q', '-m', 'Squash-merge feature/squashed']);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('branches() reports merge state, current and default flags', () async {
    final branches = await git.branches();
    final byName = {for (final b in branches) b.name: b};

    expect(byName.keys, containsAll(['main', 'feature/done', 'feature/wip']));

    expect(byName['main']!.isCurrent, isTrue);
    expect(byName['main']!.isDefault, isTrue);
    expect(byName['main']!.isProtected, isTrue);

    expect(byName['feature/done']!.isMerged, isTrue);
    expect(byName['feature/done']!.isProtected, isFalse);

    expect(byName['feature/wip']!.isMerged, isFalse);
    expect(byName['feature/wip']!.hasUpstream, isFalse);
    expect(byName['feature/wip']!.isSquashMerged, isFalse,
        reason: 'genuinely unmerged work is not squash-merged');
  });

  test('detects squash-merged branches that --merged misses', () async {
    final byName = {for (final b in await git.branches()) b.name: b};

    // Reachability does not see the squash merge…
    expect(byName['feature/squashed']!.isMerged, isFalse);
    // …but the patch-id check does.
    expect(byName['feature/squashed']!.isSquashMerged, isTrue);
    expect(byName['feature/squashed']!.isEffectivelyMerged, isTrue);

    // The genuinely unmerged branch stays unmerged either way.
    expect(byName['feature/wip']!.isEffectivelyMerged, isFalse);
  });

  test('deleteLocal refuses an unmerged branch without force, succeeds with it',
      () async {
    // Merged branch deletes with -d.
    expect((await git.deleteLocal('feature/done', force: false)).ok, isTrue);

    // Unmerged branch refuses -d…
    expect((await git.deleteLocal('feature/wip', force: false)).ok, isFalse);
    // …and is removed with -D (force).
    expect((await git.deleteLocal('feature/wip', force: true)).ok, isTrue);

    final names = (await git.branches()).map((b) => b.name).toSet();
    expect(names, isNot(contains('feature/done')));
    expect(names, isNot(contains('feature/wip')));
    expect(names, contains('main'));
  });
}
