import 'package:args/command_runner.dart';
import 'package:git_branches/git_branches.dart';

void main(List<String> arguments) async {
  final runner = CommandRunner<void>(
    'git_branches',
    '🌿 git_branches — find merged & stale local branches, then batch-delete or push.',
  )
    ..addCommand(TuiCommand())
    ..addCommand(ListCommand())
    ..addCommand(DemoCommand());

  // Default to the interactive UI when no command is given.
  if (arguments.isEmpty) {
    await TuiCommand().run();
    return;
  }
  await runner.run(arguments);
}
