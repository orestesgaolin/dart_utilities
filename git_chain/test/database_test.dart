import 'dart:io';

import 'package:git_chain/git_chain.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late ChainDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('git_chain_test');
    db = ChainDatabase.open(p.join(tmp.path, 'test.db'));
  });

  tearDown(() {
    db.close();
    tmp.deleteSync(recursive: true);
  });

  test('repo upsert is idempotent and updates metadata', () {
    final a = db.upsertRepo(
        path: '/repo', name: 'owner/repo', defaultBranch: 'main');
    final b = db.upsertRepo(
        path: '/repo', name: 'owner/repo2', defaultBranch: 'develop');
    expect(a.id, b.id);
    expect(db.getRepoByPath('/repo')!.name, 'owner/repo2');
    expect(db.getRepoByPath('/repo')!.defaultBranch, 'develop');
    expect(db.listRepos(), hasLength(1));
  });

  test('chains persist their ordered branches and PR numbers', () {
    final repo =
        db.upsertRepo(path: '/r', name: 'r', defaultBranch: 'main');
    final chain = db.createChain(
      repoId: repo.id,
      name: 'feat/2',
      targetBranch: 'main',
      branches: [
        ChainBranch(branch: 'main', position: 0),
        ChainBranch(branch: 'feat/1', position: 1, prNumber: 11),
        ChainBranch(branch: 'feat/2', position: 2, prNumber: 12),
      ],
    );
    final loaded = db.getChain(chain.id)!;
    expect(loaded.branches.map((b) => b.branch),
        ['main', 'feat/1', 'feat/2']);
    expect(loaded.branches[2].prNumber, 12);
    expect(loaded.tip, 'feat/2');
    expect(loaded.stack, hasLength(2));
  });

  test('sync runs and steps round-trip', () {
    final repo = db.upsertRepo(path: '/r', name: 'r', defaultBranch: 'main');
    final chain = db.createChain(
      repoId: repo.id,
      name: 'c',
      targetBranch: 'main',
      branches: [
        ChainBranch(branch: 'main', position: 0),
        ChainBranch(branch: 'feat/1', position: 1),
      ],
    );
    final now = DateTime.now();
    db.recordSyncRun(
      chainId: chain.id,
      strategy: SyncStrategy.rebase,
      status: 'ok',
      summary: '1 synced',
      startedAt: now,
      finishedAt: now.add(const Duration(seconds: 3)),
      steps: [
        SyncStepResult(
            branch: 'feat/1', parent: 'main', status: StepStatus.synced),
      ],
    );
    final runs = db.listSyncRuns(chain.id);
    expect(runs, hasLength(1));
    expect(runs.single.strategy, SyncStrategy.rebase);
    expect(runs.single.status, 'ok');
  });

  test('deleting a repo cascades to its chains', () {
    final repo = db.upsertRepo(path: '/r', name: 'r', defaultBranch: 'main');
    db.createChain(
      repoId: repo.id,
      name: 'c',
      targetBranch: 'main',
      branches: [ChainBranch(branch: 'main', position: 0)],
    );
    expect(db.listChains(repo.id), hasLength(1));
    db.deleteRepo(repo.id);
    expect(db.listRepos(), isEmpty);
    expect(db.listChains(repo.id), isEmpty);
  });
}
