import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../display/size_formatter.dart';
import '../storage/database.dart';

/// Removes cached scan data.
class CleanCommand extends Command<void> {
  @override
  final name = 'clean';

  @override
  final description = 'Remove cached scan data.';

  CleanCommand() {
    argParser.addFlag(
      'all',
      abbr: 'a',
      help: 'Remove all cached scan data.',
      defaultsTo: false,
    );
  }

  @override
  Future<void> run() async {
    final db = DiskDatabase.open();
    try {
      if (argResults!.flag('all')) {
        final scans = db.getAllScans();
        if (scans.isEmpty) {
          stdout.writeln('No cached scans to clean.');
          return;
        }
        db.deleteAll();
        stdout.writeln('  🧹 Removed ${scans.length} cached scan(s).');
        return;
      }

      final rest = argResults!.rest;
      if (rest.isEmpty) {
        // Show cached scans and let user choose
        final scans = db.getAllScans();
        if (scans.isEmpty) {
          stdout.writeln('No cached scans found.');
          return;
        }

        stdout.writeln('');
        stdout.writeln('  📋 Cached scans:');
        for (var i = 0; i < scans.length; i++) {
          final scan = scans[i];
          stdout.writeln(
            '    ${i + 1}. ${scan.rootPath} '
            '(${SizeFormatter.format(scan.totalSize)}, '
            '${_formatDate(scan.scannedAt)})',
          );
        }
        stdout.writeln('');
        stdout.write('  Enter number to remove (or "all"): ');
        final input = stdin.readLineSync()?.trim();
        if (input == null || input.isEmpty) return;

        if (input.toLowerCase() == 'all') {
          db.deleteAll();
          stdout.writeln('  🧹 Removed ${scans.length} cached scan(s).');
        } else {
          final index = int.tryParse(input);
          if (index == null || index < 1 || index > scans.length) {
            stderr.writeln('  Invalid selection.');
            return;
          }
          db.deleteScan(scans[index - 1].id);
          stdout.writeln('  🧹 Removed scan for: ${scans[index - 1].rootPath}');
        }
        return;
      }

      // Remove scan for specific path
      final targetPath = p.canonicalize(rest.first);
      final scan = db.getLatestScan(targetPath);
      if (scan == null) {
        stderr.writeln('No cached scan found for: $targetPath');
        return;
      }
      db.deleteScansForPath(targetPath);
      stdout.writeln('  🧹 Removed cached scan data for: $targetPath');
    } finally {
      db.close();
    }
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)} '
        '${_pad(dt.hour)}:${_pad(dt.minute)}';
  }

  String _pad(int n) => n.toString().padLeft(2, '0');
}
