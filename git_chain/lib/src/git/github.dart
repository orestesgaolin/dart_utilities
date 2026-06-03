import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models.dart';

/// Wrapper around the GitHub CLI (`gh`) for reading PR metadata.
///
/// Uses `gh` because it transparently reuses the user's existing authentication
/// and host configuration — no token plumbing required.
class GitHub {
  GitHub(this.repoRoot);

  /// Working directory used so `gh` resolves the right repository.
  final String repoRoot;

  /// A repo containing this file uses it as a static source of PR data instead
  /// of calling `gh`. Used by `git_chain demo` for offline screenshots; harmless
  /// for real repos (they never have this file).
  static const fixtureFileName = '.git_chain_prs.json';

  static bool? _available;

  /// Whether the `gh` binary is installed and on PATH.
  static Future<bool> isAvailable() async {
    if (_available != null) return _available!;
    try {
      final result = await Process.run('gh', ['--version']);
      _available = result.exitCode == 0;
    } on ProcessException {
      _available = false;
    }
    return _available!;
  }

  /// Fetches open pull requests for the repository.
  ///
  /// Returns an empty list if `gh` is unavailable, unauthenticated, or the
  /// repo has no GitHub remote — chain detection then falls back to local
  /// branches only.
  Future<List<PullRequest>> openPullRequests() async {
    // Prefer a local fixture when present (demo/offline mode).
    final fixture = File(p.join(repoRoot, fixtureFileName));
    if (fixture.existsSync()) {
      try {
        final data = jsonDecode(fixture.readAsStringSync()) as List<dynamic>;
        return data
            .cast<Map<String, dynamic>>()
            .map(PullRequest.fromJson)
            .toList();
      } on FormatException {
        return [];
      }
    }

    if (!await isAvailable()) return [];
    final result = await Process.run(
      'gh',
      [
        'pr',
        'list',
        '--state',
        'open',
        '--limit',
        '200',
        '--json',
        'number,title,headRefName,baseRefName,state,url,isDraft,mergeStateStatus,assignees',
      ],
      workingDirectory: repoRoot,
    );
    if (result.exitCode != 0) return [];
    try {
      final data = jsonDecode(result.stdout as String) as List<dynamic>;
      return data
          .cast<Map<String, dynamic>>()
          .map(PullRequest.fromJson)
          .toList();
    } on FormatException {
      return [];
    }
  }

  /// Opens [url] in the default browser (detached).
  static void openUrl(String url) {
    if (url.isEmpty) return;
    final executable = Platform.isMacOS
        ? 'open'
        : Platform.isWindows
            ? 'explorer'
            : 'xdg-open';
    Process.start(executable, [url], mode: ProcessStartMode.detached);
  }
}
