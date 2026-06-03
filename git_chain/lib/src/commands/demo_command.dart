import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../chain/chain_service.dart';
import '../git/github.dart';
import '../storage/database.dart';

/// Builds a self-contained demo repository with a realistic stacked-branch
/// layout and a local PR fixture, so the TUI can be exercised for screenshots
/// without touching GitHub.
class DemoCommand extends Command<void> {
  @override
  final name = 'demo';

  @override
  final description =
      'Create a local demo repo with dummy branches & PRs for screenshots (no GitHub).';

  DemoCommand() {
    argParser
      ..addOption('path',
          help: 'Directory to create the demo repo in.',
          valueHelp: 'dir')
      ..addFlag('force',
          abbr: 'f',
          negatable: false,
          help: 'Overwrite an existing non-demo directory at the path.');
  }

  String get _defaultPath {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.current.path;
    return p.join(home, '.git_chain', 'demo-repo');
  }

  @override
  Future<void> run() async {
    final dir = Directory(argResults!['path'] as String? ?? _defaultPath);
    final force = argResults!['force'] as bool;

    if (dir.existsSync()) {
      final isDemo =
          File(p.join(dir.path, GitHub.fixtureFileName)).existsSync();
      final empty = dir.listSync().isEmpty;
      if (!isDemo && !empty && !force) {
        stderr.writeln(
            '${dir.path} exists and is not a demo repo. Use --force to overwrite.');
        exitCode = 1;
        return;
      }
      dir.deleteSync(recursive: true);
    }
    dir.createSync(recursive: true);

    stdout.writeln('Building demo repo at ${dir.path} …');
    await _buildRepo(dir.path);
    _writeFixture(dir.path);

    // Register and detect chains using the fixture as the PR source.
    final db = ChainDatabase.open();
    final service = ChainService(db);
    try {
      final discovered = await service.registerRepo(dir.path);
      if (discovered == null) {
        stderr.writeln('Failed to register demo repo.');
        exitCode = 1;
        return;
      }
      var imported = 0;
      for (final d in await service.detectChains(discovered.repo)) {
        if (service.saveDetectedChain(discovered.repo, d) != null) imported++;
      }
      stdout.writeln('Imported $imported chain(s) from the PR fixture.');
      stdout.writeln('');
      stdout.writeln('Demo ready. Take screenshots with:');
      stdout.writeln('  cd ${dir.path} && git_chain');
      stdout.writeln('');
      stdout.writeln('Remove it later with:  rm -rf ${dir.path}');
    } finally {
      db.close();
    }
  }

  // ---- Repo construction ----------------------------------------------------

  late String _root;

  Future<void> _git(List<String> args) async {
    final result = await Process.run(
      'git',
      [
        '-c', 'user.email=demo@git-chain.local',
        '-c', 'user.name=git_chain demo',
        '-c', 'commit.gpgsign=false',
        ...args,
      ],
      workingDirectory: _root,
    );
    if (result.exitCode != 0) {
      throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
    }
  }

  Future<void> _commit(String file, String content, String message) async {
    final f = File(p.join(_root, file));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    await _git(['add', file]);
    await _git(['commit', '-q', '-m', message]);
  }

  Future<void> _buildRepo(String root) async {
    _root = root;
    await _git(['init', '-q', '-b', 'main']);
    // Make the repo look like a real GitHub project (no network is touched).
    await _git(
        ['remote', 'add', 'origin', 'https://github.com/acme/checkout-flow.git']);

    // main — keep the PR fixture out of git so the tree stays clean.
    await _commit(
        '.gitignore',
        '${GitHub.fixtureFileName}\n.dart_tool/\n',
        'chore: initial commit');
    await _commit('lib/app.dart', 'void main() {}\n', 'feat: bootstrap app');

    // Chain A: main <- feat/api-layer <- feat/ui-widgets <- feat/polish
    await _git(['checkout', '-q', '-b', 'feat/api-layer']);
    await _commit('lib/api/client.dart', '// client\n', 'feat: add API client');
    await _commit('lib/api/routes.dart', '// routes\n', 'feat: add endpoints');

    await _git(['checkout', '-q', '-b', 'feat/ui-widgets']);
    await _commit('lib/ui/cart.dart', '// cart\n', 'feat: add cart widget');
    await _commit('lib/ui/summary.dart', '// summary\n', 'feat: order summary');

    await _git(['checkout', '-q', '-b', 'feat/polish']);
    await _commit('lib/ui/theme.dart', '// theme\n', 'feat: polish styling');

    // Make children fall behind their parents so the UI shows sync state.
    await _git(['checkout', '-q', 'feat/api-layer']);
    await _commit('lib/api/errors.dart', '// errors\n', 'fix: handle API errors');
    await _git(['checkout', '-q', 'main']);
    await _commit('lib/config.dart', '// config\n', 'feat: add app config');

    // Chain B: main <- feat/payments-1 <- feat/payments-2
    await _git(['checkout', '-q', '-b', 'feat/payments-1']);
    await _commit('lib/payments/model.dart', '// model\n', 'feat: payments model');
    await _git(['checkout', '-q', '-b', 'feat/payments-2']);
    await _commit('lib/payments/view.dart', '// view\n', 'feat: payments screen');

    // A lone branch + PR (filtered out of detection by default).
    await _git(['checkout', '-q', 'main']);
    await _git(['checkout', '-q', '-b', 'chore/bump-deps']);
    await _commit('pubspec.yaml', '# deps\n', 'chore: bump dependencies');

    await _git(['checkout', '-q', 'main']);
  }

  void _writeFixture(String root) {
    Map<String, dynamic> pr(
      int number,
      String base,
      String head,
      String title, {
      List<String> assignees = const [],
      bool isDraft = false,
    }) =>
        {
          'number': number,
          'title': title,
          'headRefName': head,
          'baseRefName': base,
          'state': 'OPEN',
          'url': 'https://github.com/acme/checkout-flow/pull/$number',
          'isDraft': isDraft,
          'mergeStateStatus': 'CLEAN',
          'assignees': [for (final a in assignees) {'login': a}],
        };

    final prs = [
      pr(101, 'main', 'feat/api-layer', 'Add checkout API layer',
          assignees: ['dominik']),
      pr(102, 'feat/api-layer', 'feat/ui-widgets', 'Build cart & summary UI',
          assignees: ['alice']),
      pr(103, 'feat/ui-widgets', 'feat/polish', 'Polish checkout styling',
          assignees: ['dominik'], isDraft: true),
      pr(201, 'main', 'feat/payments-1', 'Payments data model',
          assignees: ['bob']),
      pr(202, 'feat/payments-1', 'feat/payments-2', 'Payments screen',
          assignees: ['bob', 'alice']),
      pr(301, 'main', 'chore/bump-deps', 'Bump dependencies',
          assignees: ['dependabot']),
    ];

    File(p.join(root, GitHub.fixtureFileName))
        .writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(prs)}\n');
  }
}
