import 'package:args/command_runner.dart';
import 'package:git_chain/git_chain.dart';

void main(List<String> arguments) async {
  final runner = CommandRunner<void>(
    'git_chain',
    '🔗 git_chain — visualize, synchronize, and track stacked git branch chains.',
  )
    ..addCommand(TuiCommand())
    ..addCommand(ListCommand())
    ..addCommand(ScanCommand())
    ..addCommand(SyncCommand())
    ..addCommand(DemoCommand());

  // Default to the interactive TUI when no command is given. Flags like
  // --help/--version still fall through to the runner.
  if (arguments.isEmpty) {
    await TuiCommand().run();
    return;
  }

  await runner.run(arguments);
}
