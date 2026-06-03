import 'dart:io';

import '../models.dart';

/// Result of running a git command.
class GitResult {
  GitResult(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;
}

/// A single commit, as listed between two refs.
class Commit {
  Commit(this.shortSha, this.subject);

  final String shortSha;
  final String subject;
}

/// Thin, reliable wrapper around the `git` CLI for a single repository.
///
/// We shell out to `git` rather than use a pure-Dart implementation because the
/// operations we need (rebase, merge, mergetool) are exactly what the CLI does
/// best, and behaviour matches what the user sees in their own terminal.
class GitRepo {
  GitRepo(this.root);

  /// Absolute path to the repository working tree root.
  final String root;

  /// Locates the enclosing git repository for [startDir], or null.
  static Future<GitRepo?> discover(String startDir) async {
    final result = await Process.run(
      'git',
      ['rev-parse', '--show-toplevel'],
      workingDirectory: startDir,
    );
    if (result.exitCode != 0) return null;
    final top = (result.stdout as String).trim();
    if (top.isEmpty) return null;
    return GitRepo(top);
  }

  /// Runs git non-interactively and captures output.
  ///
  /// `GIT_TERMINAL_PROMPT=0` ensures network operations (e.g. `fetch`) fail
  /// fast instead of blocking on a credential prompt we could never answer.
  Future<GitResult> run(List<String> args, {Map<String, String>? environment}) async {
    final result = await Process.run(
      'git',
      args,
      workingDirectory: root,
      environment: {'GIT_TERMINAL_PROMPT': '0', ...?environment},
    );
    return GitResult(
      result.exitCode,
      (result.stdout as String),
      (result.stderr as String),
    );
  }

  /// Runs git with the parent process's stdio inherited, so interactive tools
  /// (editors, `git mergetool`) take over the terminal. Returns the exit code.
  ///
  /// Only call this when the TUI is NOT active — it competes for the terminal.
  Future<int> runInteractive(List<String> args,
      {Map<String, String>? environment}) async {
    final process = await Process.start(
      'git',
      args,
      workingDirectory: root,
      environment: environment,
      mode: ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }

  Future<String> _line(List<String> args) async =>
      (await run(args)).stdout.trim();

  /// The default branch (`main`/`master`), best-effort.
  Future<String> defaultBranch() async {
    // Prefer origin's HEAD symbolic ref.
    final head =
        await _line(['symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD']);
    if (head.isNotEmpty) {
      final parts = head.split('/');
      if (parts.isNotEmpty) return parts.last;
    }
    for (final candidate in ['main', 'master', 'develop']) {
      if (await branchExists(candidate)) return candidate;
    }
    return await currentBranch();
  }

  Future<String> currentBranch() async =>
      _line(['rev-parse', '--abbrev-ref', 'HEAD']);

  Future<String?> remoteUrl() async {
    final url = await _line(['config', '--get', 'remote.origin.url']);
    return url.isEmpty ? null : url;
  }

  /// `owner/repo` derived from the origin URL, if it looks like GitHub.
  Future<String?> ownerRepoSlug() async {
    final url = await remoteUrl();
    if (url == null) return null;
    // git@github.com:owner/repo.git  or  https://github.com/owner/repo.git
    final match = RegExp(r'[:/]([^/:]+/[^/]+?)(?:\.git)?$').firstMatch(url);
    return match?.group(1);
  }

  Future<bool> branchExists(String branch) async {
    final result =
        await run(['rev-parse', '--verify', '--quiet', 'refs/heads/$branch']);
    return result.ok && result.stdout.trim().isNotEmpty;
  }

  /// All local branch names.
  Future<List<String>> localBranches() async {
    final out =
        await _line(['for-each-ref', '--format=%(refname:short)', 'refs/heads']);
    if (out.isEmpty) return [];
    return out.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }

  /// Whether the working tree has uncommitted changes.
  Future<bool> isDirty() async {
    final out = await _line(['status', '--porcelain']);
    return out.isNotEmpty;
  }

  /// Subject line of the most recent commit on [branch].
  Future<String?> lastCommitSubject(String branch) async {
    final result = await run(['log', '-1', '--format=%s', branch]);
    if (!result.ok) return null;
    final s = result.stdout.trim();
    return s.isEmpty ? null : s;
  }

  /// Commits [branch] is ahead/behind relative to [base].
  ///
  /// `ahead` = commits on [branch] not in [base]; `behind` = the reverse.
  Future<(int ahead, int behind)> aheadBehind(String branch, String base) async {
    final result =
        await run(['rev-list', '--left-right', '--count', '$base...$branch']);
    if (!result.ok) return (0, 0);
    final parts = result.stdout.trim().split(RegExp(r'\s+'));
    if (parts.length != 2) return (0, 0);
    final behind = int.tryParse(parts[0]) ?? 0; // left = base-only
    final ahead = int.tryParse(parts[1]) ?? 0; // right = branch-only
    return (ahead, behind);
  }

  /// Upstream (remote tracking) ahead/behind for [branch], if it has one.
  Future<(int ahead, int behind)?> upstreamAheadBehind(String branch) async {
    final upstream = await _line(
        ['rev-parse', '--abbrev-ref', '--symbolic-full-name', '$branch@{upstream}']);
    if (upstream.isEmpty) return null;
    return aheadBehind(branch, upstream);
  }

  /// Fetches all remotes and prunes deleted branches.
  Future<GitResult> fetchAll() => run(['fetch', '--all', '--prune']);

  /// Fast-forwards the local [branch] to its upstream, without checking it out.
  ///
  /// Returns null on success, or an error message.
  Future<String?> fastForwardToUpstream(String branch) async {
    final upstream = await _line(
        ['rev-parse', '--abbrev-ref', '--symbolic-full-name', '$branch@{upstream}']);
    if (upstream.isEmpty) {
      return 'no upstream configured for $branch';
    }
    final current = await currentBranch();
    if (current == branch) {
      final result = await run(['merge', '--ff-only', upstream]);
      return result.ok ? null : result.stderr.trim();
    }
    // Update the ref directly when the branch isn't checked out (only works for
    // a true fast-forward; refuses otherwise, which is what we want).
    final result =
        await run(['fetch', '.', '$upstream:$branch']);
    return result.ok ? null : result.stderr.trim();
  }

  Future<GitResult> checkout(String branch) => run(['checkout', branch]);

  // ---- Named stashes --------------------------------------------------------
  //
  // git_chain creates stashes with an explicit, recognizable label so they are
  // easy to spot in `git stash list` and to recover by hand if an auto-restore
  // ever conflicts.

  /// Prefix applied to every stash git_chain creates.
  static const stashPrefix = 'git_chain';

  /// Builds an explicit stash label, e.g.
  /// `git_chain: checkout feat/2 @ 2026-06-03T12:00:00`.
  static String stashLabel(String reason) {
    final ts = DateTime.now().toIso8601String().split('.').first;
    return '$stashPrefix: $reason @ $ts';
  }

  /// Stashes the working tree (including untracked files) under [message].
  Future<GitResult> stashPush(String message) =>
      run(['stash', 'push', '--include-untracked', '-m', message]);

  /// Finds the `stash@{n}` ref whose subject contains [message], or null.
  Future<String?> stashRefByMessage(String message) async {
    final result = await run(['stash', 'list', '--format=%gd%x1f%gs']);
    if (!result.ok) return null;
    final sep = String.fromCharCode(0x1f);
    for (final line in result.stdout.split('\n')) {
      if (line.isEmpty) continue;
      final parts = line.split(sep);
      if (parts.length >= 2 && parts[1].contains(message)) return parts[0];
    }
    return null;
  }

  /// Pops the stash labelled [message]. Returns null on success, or an error
  /// message (e.g. when the pop conflicts and the stash is kept).
  Future<String?> stashPopByMessage(String message) async {
    final ref = await stashRefByMessage(message);
    if (ref == null) return 'stash "$message" not found';
    final result = await run(['stash', 'pop', ref]);
    return result.ok ? null : result.stderr.trim().split('\n').first;
  }

  /// Files currently in an unmerged (conflicted) state.
  Future<List<String>> conflictedFiles() async {
    final out = await _line(['diff', '--name-only', '--diff-filter=U']);
    if (out.isEmpty) return [];
    return out.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }

  /// Commits on [branch] but not on [parent] (i.e. `parent..branch`),
  /// excluding merge commits, newest first.
  Future<List<Commit>> commitsBetween(String parent, String branch,
      {int limit = 100}) async {
    final result = await run([
      'log',
      '--no-merges',
      '--format=%h%x1f%s',
      '--max-count=$limit',
      '$parent..$branch',
    ]);
    if (!result.ok) return [];
    final out = result.stdout.trim();
    if (out.isEmpty) return [];
    return out.split('\n').where((l) => l.isNotEmpty).map((line) {
      final parts = line.split(String.fromCharCode(0x1f));
      return Commit(parts[0], parts.length > 1 ? parts[1] : '');
    }).toList();
  }

  /// Computes the live status of every branch in [chain] against its parent.
  Future<List<BranchStatus>> chainStatus(Chain chain) async {
    final statuses = <BranchStatus>[];
    for (var i = 1; i < chain.branches.length; i++) {
      final branch = chain.branches[i].branch;
      final parent = chain.branches[i - 1].branch;
      final exists = await branchExists(branch);
      if (!exists) {
        statuses.add(BranchStatus(branch: branch, exists: false, ahead: 0, behind: 0));
        continue;
      }
      final (ahead, behind) = await aheadBehind(branch, parent);
      final upstream = await upstreamAheadBehind(branch);
      statuses.add(BranchStatus(
        branch: branch,
        exists: true,
        ahead: ahead,
        behind: behind,
        lastCommitSubject: await lastCommitSubject(branch),
        upstreamAhead: upstream?.$1,
        upstreamBehind: upstream?.$2,
      ));
    }
    return statuses;
  }
}
