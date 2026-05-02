import 'package:args/command_runner.dart';
import 'package:disk_analyzer_cli/disk_analyzer_cli.dart';

void main(List<String> arguments) async {
  final runner = CommandRunner<void>(
    'disk_analyzer_cli',
    '📊 Disk Analyzer CLI — Analyze disk space, visualize usage, and clean up files.',
  )
    ..addCommand(ScanCommand())
    ..addCommand(ShowCommand())
    ..addCommand(DeleteCommand())
    ..addCommand(CleanCommand())
    ..addCommand(TuiCommand());

  await runner.run(arguments);
}
