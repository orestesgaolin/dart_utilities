import 'dart:io';
import 'package:nocterm/nocterm.dart';

class Mini extends StatelessComponent {
  const Mini({super.key});
  @override
  Component build(BuildContext context) => Focusable(
      focused: true,
      onKeyEvent: (e) { shutdownApp(); return true; },
      child: Text('hi'));
}

void main() async {
  await runApp(const Mini());
  stdout.writeln('\nAFTER_RUNAPP_1');
  stdout.write('prompt: ');
  final line = stdin.readLineSync();
  stdout.writeln('GOT_LINE=[$line]');
  await runApp(const Mini());
  stdout.writeln('\nAFTER_RUNAPP_2');
}
