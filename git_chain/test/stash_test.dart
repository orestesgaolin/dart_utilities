import 'dart:io';

import 'package:git_chain/git_chain.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// These tests drive a real, throwaway git repository to exercise the stash
/// plumbing end-to-end.
void main() {
  late Directory tmp;
  late GitRepo git;

  Future<void> run(List<String> args) async {
    final r = await Process.run('git', args, workingDirectory: tmp.path);
    if (r.exitCode != 0) {
      throw StateError('git ${args.join(' ')} failed: ${r.stderr}');
    }
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('git_chain_stash');
    git = GitRepo(tmp.path);
    await run(['init', '-q']);
    await run(['config', 'user.email', 'test@example.com']);
    await run(['config', 'user.name', 'Test']);
    File(p.join(tmp.path, 'file.txt')).writeAsStringSync('one\n');
    await run(['add', '.']);
    await run(['commit', '-q', '-m', 'initial']);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('named stash push / find / pop round-trips and restores changes',
      () async {
    // Make the tree dirty.
    File(p.join(tmp.path, 'file.txt')).writeAsStringSync('one\ntwo\n');
    expect(await git.isDirty(), isTrue);

    final label = GitRepo.stashLabel('checkout feature');
    expect(label, startsWith('git_chain:'));

    final pushed = await git.stashPush(label);
    expect(pushed.ok, isTrue);
    expect(await git.isDirty(), isFalse, reason: 'tree clean after stash');

    final ref = await git.stashRefByMessage(label);
    expect(ref, isNotNull);
    expect(ref, startsWith('stash@{'));

    final popError = await git.stashPopByMessage(label);
    expect(popError, isNull, reason: 'pop succeeds');
    expect(await git.isDirty(), isTrue, reason: 'changes restored');
    expect(
      File(p.join(tmp.path, 'file.txt')).readAsStringSync(),
      'one\ntwo\n',
    );
  });

  test('stashPopByMessage reports when no matching stash exists', () async {
    final error = await git.stashPopByMessage('git_chain: nonexistent');
    expect(error, isNotNull);
  });
}
