import 'dart:io';

import 'package:git_chain/git_chain.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Verifies the conflict handling the in-app sync relies on: a conflicting
/// rebase invokes the resolver, and returning false aborts cleanly.
void main() {
  late Directory tmp;
  late GitRepo git;

  Future<void> run(List<String> args) async {
    final r = await Process.run('git', args, workingDirectory: tmp.path);
    if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
  }

  void write(String content) =>
      File(p.join(tmp.path, 'file.txt')).writeAsStringSync(content);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('git_chain_conflict');
    git = GitRepo(tmp.path);
    await run(['init', '-q', '-b', 'main']);
    await run(['config', 'user.email', 't@e.com']);
    await run(['config', 'user.name', 'T']);
    write('base\n');
    await run(['add', '.']);
    await run(['commit', '-q', '-m', 'base']);
    // feat diverges on the same line as main will.
    await run(['checkout', '-q', '-b', 'feat']);
    write('feature\n');
    await run(['add', '.']);
    await run(['commit', '-q', '-m', 'feat change']);
    await run(['checkout', '-q', 'main']);
    write('mainline\n');
    await run(['add', '.']);
    await run(['commit', '-q', '-m', 'main change']);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('conflicting rebase calls the resolver and aborts cleanly on false',
      () async {
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

    String? conflictedBranch;
    List<String> conflictedFiles = [];
    final engine = SyncEngine(
      repo: git,
      log: (_) {},
      resolveConflict: (branch, files) async {
        conflictedBranch = branch;
        conflictedFiles = files;
        return false; // mimic the in-app "hand off to shell" decision
      },
    );

    final outcome = await engine.run(chain, SyncStrategy.rebase);

    expect(conflictedBranch, 'feat');
    expect(conflictedFiles, contains('file.txt'));
    expect(outcome.status, 'aborted');
    // Tree is clean and no rebase is in progress after the abort.
    expect(await git.isDirty(), isFalse);
    expect(await git.conflictedFiles(), isEmpty);
    expect(Directory(p.join(tmp.path, '.git', 'rebase-merge')).existsSync(),
        isFalse);
  });
}
