import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../display/size_formatter.dart';
import '../storage/database.dart';

/// Deletes files or folders with confirmation.
class DeleteCommand extends Command<void> {
  @override
  final name = 'delete';

  @override
  final description = 'Delete a file or folder (with confirmation).';

  DeleteCommand() {
    argParser
      ..addFlag(
        'force',
        abbr: 'f',
        help: 'Skip confirmation prompt.',
        defaultsTo: false,
      )
      ..addFlag(
        'dry-run',
        abbr: 'n',
        help: 'Show what would be deleted without actually deleting.',
        defaultsTo: false,
      );
  }

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      stderr.writeln('Error: Please specify a path to delete.');
      stderr.writeln('Usage: disk_analyzer_cli delete <path>');
      return;
    }

    final targetPath = p.canonicalize(rest.first);
    final force = argResults!.flag('force');
    final dryRun = argResults!.flag('dry-run');

    // Check if path exists
    final type = FileSystemEntity.typeSync(targetPath);
    if (type == FileSystemEntityType.notFound) {
      stderr.writeln('Error: Path does not exist: $targetPath');
      return;
    }

    // Calculate size
    int size;
    String entityType;
    if (type == FileSystemEntityType.directory) {
      entityType = 'directory';
      size = await _calculateDirSize(Directory(targetPath));
    } else {
      entityType = 'file';
      size = File(targetPath).lengthSync();
    }

    stdout.writeln('');
    stdout.writeln('  🗑️  Delete $entityType: $targetPath');
    stdout.writeln('  Size: ${SizeFormatter.format(size)}');
    stdout.writeln('');

    if (dryRun) {
      stdout.writeln('  [DRY RUN] Would delete $entityType ($targetPath)');
      return;
    }

    if (!force) {
      stdout.write('  Are you sure? (y/N) ');
      final answer = stdin.readLineSync()?.trim().toLowerCase();
      if (answer != 'y' && answer != 'yes') {
        stdout.writeln('  Cancelled.');
        return;
      }
    }

    try {
      if (type == FileSystemEntityType.directory) {
        Directory(targetPath).deleteSync(recursive: true);
      } else {
        File(targetPath).deleteSync();
      }
      stdout.writeln('  ✅ Deleted: $targetPath');
      stdout.writeln('  💾 Freed: ${SizeFormatter.format(size)}');

      // Invalidate any cached scans that contain this path
      final db = DiskDatabase.open();
      try {
        final scan = db.findScanContaining(targetPath);
        if (scan != null) {
          stdout.writeln('');
          stdout.writeln('  ℹ️  Cached scan data is now stale.');
          stdout.writeln('  Run `disk_analyzer_cli scan ${scan.rootPath}` to refresh.');
        }
      } finally {
        db.close();
      }
    } catch (e) {
      stderr.writeln('  ❌ Failed to delete: $e');
    }
  }

  Future<int> _calculateDirSize(Directory dir) async {
    var total = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += entity.lengthSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }
}
