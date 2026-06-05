import 'dart:io';

import '../models.dart';

/// Result of running a git command.
class GitResult {
  GitResult(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;

  /// First non-empty line of stderr (or stdout), for compact error display.
  String get firstError {
    final err = stderr.trim().isNotEmpty ? stderr.trim() : stdout.trim();
    return err.isEmpty ? 'failed' : err.split('\n').first;
  }
}

/// Wrapper around the `git` CLI for a single repository, scoped to the branch
/// operations git_branches needs.
class GitRepo {
  GitRepo(this.root);

  final String root;

  static Future<GitRepo?> discover(String startDir) async {
    final result = await Process.run(
      'git',
      ['rev-parse', '--show-toplevel'],
      workingDirectory: startDir,
    );
    if (result.exitCode != 0) return null;
    final top = (result.stdout as String).trim();
    return top.isEmpty ? null : GitRepo(top);
  }

  /// Runs git non-interactively. `GIT_TERMINAL_PROMPT=0` makes networked
  /// commands fail fast instead of blocking on a credential prompt.
  Future<GitResult> run(List<String> args) async {
    final result = await Process.run(
      'git',
      args,
      workingDirectory: root,
      environment: const {'GIT_TERMINAL_PROMPT': '0'},
    );
    return GitResult(result.exitCode, result.stdout as String, result.stderr as String);
  }

  Future<String> _line(List<String> args) async => (await run(args)).stdout.trim();

  Future<String> currentBranch() async =>
      _line(['rev-parse', '--abbrev-ref', 'HEAD']);

  /// Best-effort default branch (`main`/`master`/origin HEAD).
  Future<String> defaultBranch() async {
    final head =
        await _line(['symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD']);
    if (head.isNotEmpty) return head.split('/').last;
    for (final candidate in ['main', 'master', 'develop']) {
      final exists = await run(
          ['rev-parse', '--verify', '--quiet', 'refs/heads/$candidate']);
      if (exists.ok && exists.stdout.trim().isNotEmpty) return candidate;
    }
    return currentBranch();
  }

  Future<String?> ownerRepoSlug() async {
    final url = await _line(['config', '--get', 'remote.origin.url']);
    if (url.isEmpty) return null;
    final match = RegExp(r'[:/]([^/:]+/[^/]+?)(?:\.git)?$').firstMatch(url);
    return match?.group(1);
  }

  static const _sep = '\x1f';

  /// Cache of squash-merge results, keyed by `<baseSha>\x00<branchSha>`, so
  /// reloads after an action (which don't move most branches) stay fast.
  final _squashCache = <String, bool>{};

  /// Lists every local branch with merge state (including squash/rebase
  /// merges), last activity, and upstream tracking info.
  Future<List<BranchInfo>> branches({bool detectSquashMerges = true}) async {
    final def = await defaultBranch();
    final baseSha = (await run(['rev-parse', def])).stdout.trim();

    final mergedResult =
        await run(['branch', '--merged', def, '--format=%(refname:short)']);
    final merged = mergedResult.ok
        ? mergedResult.stdout
            .split('\n')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toSet()
        : <String>{};

    final fields = [
      '%(refname:short)',
      '%(committerdate:unix)',
      '%(committerdate:relative)',
      '%(upstream:short)',
      '%(upstream:track)',
      '%(HEAD)',
      '%(objectname)',
      '%(contents:subject)',
    ].join(_sep);

    final result = await run(['for-each-ref', '--format=$fields', 'refs/heads']);
    if (!result.ok) return [];

    // First pass: parse the raw records.
    final records = <_BranchRecord>[];
    for (final line in result.stdout.split('\n')) {
      if (line.trim().isEmpty) continue;
      final f = line.split(_sep);
      if (f.length < 8) continue;
      final (ahead, behind, gone) = _parseTrack(f[4].trim());
      records.add(_BranchRecord(
        name: f[0],
        unix: int.tryParse(f[1].trim()) ?? 0,
        relative: f[2].trim(),
        upstream: f[3].trim(),
        isCurrent: f[5].trim() == '*',
        tipSha: f[6].trim(),
        subject: f[7],
        ahead: ahead,
        behind: behind,
        gone: gone,
        isDefault: f[0] == def,
        isMerged: merged.contains(f[0]),
      ));
    }

    // Second pass: detect squash/rebase merges for branches that reachability
    // didn't catch (and that aren't the current/default branch).
    var squashed = <String>{};
    if (detectSquashMerges && baseSha.isNotEmpty) {
      final candidates = records
          .where((r) => !r.isMerged && !r.isDefault && !r.isCurrent)
          .toList();
      squashed = await _squashMergedSet(def, baseSha, candidates);
    }

    return [
      for (final r in records)
        BranchInfo(
          name: r.name,
          isCurrent: r.isCurrent,
          isDefault: r.isDefault,
          isMerged: r.isMerged,
          isSquashMerged: squashed.contains(r.name),
          lastActivity: DateTime.fromMillisecondsSinceEpoch(r.unix * 1000),
          relativeDate: r.relative,
          subject: r.subject,
          upstream: r.upstream.isEmpty ? null : r.upstream,
          ahead: r.ahead,
          behind: r.behind,
          upstreamGone: r.gone,
        ),
    ];
  }

  /// Returns the names of [candidates] whose net changes are already present on
  /// [base] via a squash/rebase merge.
  ///
  /// Reachability (`--merged`) can't see these: a squash merge creates one new
  /// commit on [base] with no ancestry link to the branch. Instead, for each
  /// branch we synthesize a single commit holding the branch's diff against its
  /// merge-base and ask `git cherry` whether that patch already exists on
  /// [base] (patch-id match). Results are cached by (base, branch) tip sha.
  Future<Set<String>> _squashMergedSet(
      String base, String baseSha, List<_BranchRecord> candidates) async {
    final result = <String>{};
    final queue = List.of(candidates);
    const poolSize = 12;

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final r = queue.removeLast();
        if (await _isSquashMerged(base, baseSha, r.name, r.tipSha)) {
          result.add(r.name);
        }
      }
    }

    await Future.wait([for (var i = 0; i < poolSize; i++) worker()]);
    return result;
  }

  Future<bool> _isSquashMerged(
      String base, String baseSha, String branch, String tipSha) async {
    final cacheKey = '$baseSha\x00$tipSha';
    final cached = _squashCache[cacheKey];
    if (cached != null) return cached;

    Future<bool> compute() async {
      final mb = await run(['merge-base', base, branch]);
      if (!mb.ok || mb.stdout.trim().isEmpty) return false;
      final mergeBase = mb.stdout.trim();
      // Synthesize a commit with the branch's tree on top of the merge-base.
      final fake = await run([
        '-c', 'user.name=git_branches',
        '-c', 'user.email=git_branches@local',
        'commit-tree', '$branch^{tree}', '-p', mergeBase, '-m', '_',
      ]);
      if (!fake.ok || fake.stdout.trim().isEmpty) return false;
      // `git cherry` marks commits whose patch already exists upstream with '-'.
      final cherry = await run(['cherry', base, fake.stdout.trim()]);
      if (!cherry.ok) return false;
      final out = cherry.stdout.trim();
      return out.isEmpty || out.startsWith('-');
    }

    final value = await compute();
    _squashCache[cacheKey] = value;
    return value;
  }

  /// Parses git's `upstream:track` field, e.g. `[ahead 2, behind 1]`, `[gone]`.
  (int ahead, int behind, bool gone) _parseTrack(String track) {
    if (track.contains('gone')) return (0, 0, true);
    final ahead =
        int.tryParse(RegExp(r'ahead (\d+)').firstMatch(track)?.group(1) ?? '') ?? 0;
    final behind =
        int.tryParse(RegExp(r'behind (\d+)').firstMatch(track)?.group(1) ?? '') ?? 0;
    return (ahead, behind, false);
  }

  /// Deletes a local branch. Uses `-D` (force) when [force] is set, which is
  /// required for branches not merged into the default branch.
  Future<GitResult> deleteLocal(String branch, {required bool force}) =>
      run(['branch', force ? '-D' : '-d', branch]);

  /// Pushes [branch] to origin, setting the upstream when [setUpstream] is set.
  Future<GitResult> push(String branch, {required bool setUpstream}) => run([
        'push',
        if (setUpstream) '-u',
        'origin',
        branch,
      ]);
}

/// Raw parsed `for-each-ref` row, before squash-merge detection.
class _BranchRecord {
  _BranchRecord({
    required this.name,
    required this.unix,
    required this.relative,
    required this.upstream,
    required this.isCurrent,
    required this.tipSha,
    required this.subject,
    required this.ahead,
    required this.behind,
    required this.gone,
    required this.isDefault,
    required this.isMerged,
  });

  final String name;
  final int unix;
  final String relative;
  final String upstream;
  final bool isCurrent;
  final String tipSha;
  final String subject;
  final int ahead;
  final int behind;
  final bool gone;
  final bool isDefault;
  final bool isMerged;
}
