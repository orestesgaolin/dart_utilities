import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

import '../display/tui_app.dart';
import '../storage/database.dart';

/// Launches an interactive TUI for exploring disk usage.
class TuiCommand extends Command<void> {
  @override
  final name = 'tui';

  @override
  final description = 'Interactive terminal UI to explore disk usage.';

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    final targetPath = rest.isEmpty ? Directory.current.path : rest.first;
    final absPath = p.canonicalize(targetPath);

    final db = DiskDatabase.open();

    // Find the relevant scan
    var scan = db.getLatestScan(absPath);
    scan ??= db.findScanContaining(absPath);

    if (scan == null) {
      stderr.writeln('No cached scan data found for: $absPath');
      stderr.writeln('Run `disk_analyzer_cli scan $absPath` first.');
      db.close();
      return;
    }

    runApp(DiskUsageApp(db: db, scanId: scan.id, rootPath: absPath));
  }
}
