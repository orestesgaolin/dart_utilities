import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:nocterm/nocterm.dart';

import '../chain/chain_service.dart';
import '../chain/interactive_sync.dart';
import '../display/app_intent.dart';
import '../display/tui_app.dart';
import '../git/git_repo.dart';
import '../storage/database.dart';

/// Launches the interactive TUI. This is the default command.
class TuiCommand extends Command<void> {
  @override
  final name = 'tui';

  @override
  final description =
      'Interactive UI to visualize and sync branch chains (default).';

  @override
  Future<void> run() async {
    final db = ChainDatabase.open();
    final service = ChainService(db);

    // If launched inside a git repo, register it and jump straight to it.
    final discovered = await service.registerRepo(Directory.current.path);

    final intent = AppIntent();
    await runApp(GitChainApp(
      db: db,
      service: service,
      intent: intent,
      initialRepo: discovered?.repo,
      initialGit: discovered?.git,
    ));

    // A sync requested from the TUI runs here, after the UI released the
    // terminal — so `git mergetool` and prompts get full stdin/stdout. We do
    // not re-enter the TUI afterwards (re-launch `git_chain` to continue).
    final request = intent.syncRequest;
    if (request != null) {
      final git = GitRepo(request.repo.path);
      await runInteractiveSync(
        db: db,
        git: git,
        chain: request.chain,
        strategy: request.strategy,
      );
      stdout.writeln('\nRun `git_chain` again to return to the UI.');
    }
    db.close();
    // The UI was stopped via binding.shutdown() (not exit()), so lingering
    // stdin/terminal resources could keep the VM alive — exit explicitly.
    exit(0);
  }
}
