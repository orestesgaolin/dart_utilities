import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

/// Builds a self-contained demo repo (with a local bare remote, so push works)
/// containing merged, stale, push-pending, and gone-upstream branches — for
/// trying out git_branches and taking screenshots, with no real network.
class DemoCommand extends Command<void> {
  @override
  final name = 'demo';

  @override
  final description =
      'Create a local demo repo with merged/stale/pushable branches (no network).';

  DemoCommand() {
    argParser
      ..addOption('path', help: 'Directory for the demo repo.', valueHelp: 'dir')
      ..addFlag('force',
          abbr: 'f', negatable: false, help: 'Overwrite an existing directory.');
  }

  String get _home =>
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.current.path;

  late String _root;

  @override
  Future<void> run() async {
    final repoDir =
        Directory(argResults!['path'] as String? ?? p.join(_home, '.git_branches', 'demo-repo'));
    // Name the bare remote acme/webapp.git so the repo shows as "acme/webapp".
    final remoteDir =
        Directory(p.join(repoDir.parent.path, 'acme', 'webapp.git'));
    final force = argResults!['force'] as bool;

    if (repoDir.existsSync()) {
      final looksLikeDemo =
          Directory(p.join(repoDir.path, '.git')).existsSync();
      if (!looksLikeDemo && repoDir.listSync().isNotEmpty && !force) {
        stderr.writeln('${repoDir.path} exists and is not a demo. Use --force.');
        exitCode = 1;
        return;
      }
      repoDir.deleteSync(recursive: true);
    }
    if (remoteDir.existsSync()) remoteDir.deleteSync(recursive: true);
    repoDir.createSync(recursive: true);
    remoteDir.createSync(recursive: true);

    stdout.writeln('Building demo repo at ${repoDir.path} …');
    _root = repoDir.path;
    await _build(remoteDir.path);

    stdout.writeln('Demo ready. Try it with:');
    stdout.writeln('  cd ${repoDir.path} && git_branches');
    stdout.writeln('');
    stdout.writeln('Remove it later with:');
    stdout.writeln('  rm -rf ${repoDir.path} ${remoteDir.path}');
  }

  Future<void> _git(List<String> args, {DateTime? date}) async {
    final env = {
      'GIT_TERMINAL_PROMPT': '0',
      if (date != null) ...{
        'GIT_AUTHOR_DATE': date.toIso8601String(),
        'GIT_COMMITTER_DATE': date.toIso8601String(),
      },
    };
    final result = await Process.run(
      'git',
      ['-c', 'user.email=demo@git-branches.local', '-c', 'user.name=git_branches demo', ...args],
      workingDirectory: _root,
      environment: env,
    );
    if (result.exitCode != 0) {
      throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
    }
  }

  Future<void> _commit(String file, String content, String message,
      {DateTime? date}) async {
    final f = File(p.join(_root, file));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    await _git(['add', file]);
    await _git(['commit', '-q', '-m', message], date: date);
  }

  Future<void> _build(String remotePath) async {
    final now = DateTime.now();
    DateTime daysAgo(int d) => now.subtract(Duration(days: d));

    // Initialise the local bare remote so pushes work without a network.
    final bare = await Process.run('git', ['init', '--bare', '-q', remotePath]);
    if (bare.exitCode != 0) {
      throw StateError('git init --bare failed: ${bare.stderr}');
    }

    await _git(['init', '-q', '-b', 'main']);
    await _git(['remote', 'add', 'origin', remotePath]);

    await _commit('README.md', '# demo\n', 'chore: initial commit', date: daysAgo(120));
    await _commit('lib/app.dart', 'void main() {}\n', 'feat: app shell', date: daysAgo(100));
    await _git(['push', '-q', '-u', 'origin', 'main']);

    // Two merged branches (safe to delete with -d).
    await _mergedBranch('feature/login-form', 'lib/login.dart', daysAgo(40));
    await _mergedBranch('bugfix/typo-in-readme', 'README.md', daysAgo(30),
        content: '# demo\n\nfixed typo\n');

    // A squash-merged branch: its work is on main as one new commit with no
    // ancestry link, so `git branch --merged` misses it but git_branches
    // detects it via patch-id and shows "squashed".
    await _git(['checkout', '-q', '-b', 'feature/squash-merged', 'main']);
    await _commit('lib/squashed.dart', '// squashed\n', 'feat: squashed work',
        date: daysAgo(35));
    await _git(['checkout', '-q', 'main']);
    await _git(['merge', '-q', '--squash', 'feature/squash-merged']);
    await _git(['commit', '-q', '-m', 'feat: squashed work (#42)'], date: daysAgo(35));
    await _git(['push', '-q', 'origin', 'main']);

    // A pushed, up-to-date feature branch (has upstream, nothing to push).
    await _git(['checkout', '-q', '-b', 'feature/dashboard', 'main']);
    await _commit('lib/dashboard.dart', '// dashboard\n', 'feat: dashboard', date: daysAgo(10));
    await _git(['push', '-q', '-u', 'origin', 'feature/dashboard']);

    // A branch with local commits not yet pushed (needs push).
    await _git(['checkout', '-q', '-b', 'wip/refactor-api', 'main']);
    await _commit('lib/api.dart', '// api\n', 'refactor: api client', date: daysAgo(5));
    await _git(['push', '-q', '-u', 'origin', 'wip/refactor-api']);
    await _commit('lib/api.dart', '// api v2\n', 'refactor: more api work', date: daysAgo(2));

    // Stale unmerged branches (old, no upstream) — force-delete candidates.
    await _git(['checkout', '-q', '-b', 'chore/old-cleanup', 'main']);
    await _commit('lib/old.dart', '// old\n', 'chore: abandoned cleanup', date: daysAgo(220));
    await _git(['checkout', '-q', '-b', 'experiment/spike', 'main']);
    await _commit('lib/spike.dart', '// spike\n', 'spike: throwaway idea', date: daysAgo(180));

    // A branch whose remote was deleted (upstream gone).
    await _git(['checkout', '-q', '-b', 'feature/shipped', 'main']);
    await _commit('lib/shipped.dart', '// shipped\n', 'feat: shipped feature', date: daysAgo(50));
    await _git(['push', '-q', '-u', 'origin', 'feature/shipped']);
    await _git(['push', '-q', 'origin', '--delete', 'feature/shipped']);
    await _git(['fetch', '-q', '--prune', 'origin']);

    await _git(['checkout', '-q', 'main']);
  }

  Future<void> _mergedBranch(String branch, String file, DateTime date,
      {String content = '// merged work\n'}) async {
    await _git(['checkout', '-q', '-b', branch, 'main']);
    await _commit(file, content, 'feat: $branch', date: date);
    await _git(['checkout', '-q', 'main']);
    await _git(['merge', '-q', '--no-ff', '-m', 'Merge $branch', branch], date: date);
    await _git(['push', '-q', 'origin', 'main']);
  }
}
