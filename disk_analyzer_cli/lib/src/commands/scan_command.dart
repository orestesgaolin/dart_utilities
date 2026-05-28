import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../config.dart';
import '../display/size_formatter.dart';
import '../scanner/disk_scanner.dart';
import '../storage/database.dart';
import '../storage/models.dart';

/// Scans a directory and caches the results in SQLite.
class ScanCommand extends Command<void> {
  @override
  final name = 'scan';

  @override
  final description = 'Scan a directory and cache disk usage data.';

  ScanCommand() {
    argParser
      ..addFlag(
        'follow-links',
        help: 'Follow symbolic links.',
        defaultsTo: false,
      )
      ..addOption('max-depth', help: 'Maximum depth to scan.', valueHelp: 'N')
      ..addOption(
        'timeout',
        help: 'Stop scanning after this duration (e.g., 5m, 1h, 30s).',
        valueHelp: 'DURATION',
      )
      ..addMultiOption(
        'ignore-dirs',
        help:
            'Directory names to collapse (record size only, don\'t recurse). '
            'Defaults to config file values (node_modules, .git).',
        valueHelp: 'NAME',
      )
      ..addOption(
        'batch-size',
        help: 'Number of entries to insert per SQLite transaction.',
        defaultsTo: '5000',
        valueHelp: 'N',
      );
  }

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    final targetPath = rest.isEmpty ? Directory.current.path : rest.first;
    final absPath = p.canonicalize(targetPath);

    if (!Directory(absPath).existsSync()) {
      stderr.writeln('Error: Directory does not exist: $absPath');
      return;
    }

    final followLinks = argResults!.flag('follow-links');
    final maxDepthStr = argResults!.option('max-depth');
    final maxDepth = maxDepthStr != null ? int.tryParse(maxDepthStr) : null;
    final timeoutStr = argResults!.option('timeout');
    final timeout = timeoutStr != null ? _parseDuration(timeoutStr) : null;
    final ignoreDirsArg = argResults!.multiOption('ignore-dirs');
    final batchSizeStr = argResults!.option('batch-size')!;
    final batchSize = int.tryParse(batchSizeStr);

    if (timeoutStr != null && timeout == null) {
      stderr.writeln('Error: Invalid timeout format. Use e.g., 30s, 5m, 1h.');
      return;
    }
    if (batchSize == null || batchSize <= 0) {
      stderr.writeln('Error: --batch-size must be a positive integer.');
      return;
    }

    // Use CLI override or fall back to config file
    final config = AnalyzerConfig.load();
    final collapsedDirs = ignoreDirsArg.isNotEmpty
        ? ignoreDirsArg
        : config.collapsedDirs;

    final scanner = DiskScanner(
      followLinks: followLinks,
      maxDepth: maxDepth,
      timeout: timeout,
      collapsedDirs: collapsedDirs,
    );

    final db = DiskDatabase.open();

    // Check if we should merge into a parent scan
    final parentScan = db.findParentScan(absPath);
    final merging = parentScan != null;
    int scanId;
    int depthOffset = 0;

    if (merging) {
      scanId = parentScan.id;
      // Get the depth of this subfolder within the parent scan
      final parentDepth = db.getEntryDepth(scanId, absPath);
      if (parentDepth != null) {
        depthOffset = parentDepth;
      } else {
        // Subfolder doesn't exist in parent scan yet — calculate from path
        final rootPath = parentScan.rootPath;
        depthOffset = absPath.split('/').length - rootPath.split('/').length;
      }
      // Delete old subtree entries (we'll replace them)
      db.deleteSubtree(scanId, absPath);
      stdout.writeln(
        '  📎 Merging into parent scan #$scanId (${parentScan.rootPath})',
      );
    } else {
      scanId = db.createScan(rootPath: absPath);
    }

    final writer = db.batchWriter(scanId, batchSize: batchSize);

    stdout.write('  🔍 Scanning $absPath ...');
    if (timeout != null) {
      stdout.write(' (timeout: $timeoutStr)');
    }
    stdout.writeln('');

    final stopwatch = Stopwatch()..start();
    var lastSaveTime = DateTime.now();

    // Add root entry
    writer.add(
      FileEntry(
        path: absPath,
        isDirectory: true,
        size: 0, // Will be updated at end
        depth: depthOffset,
        parentPath: merging ? p.dirname(absPath) : null,
      ),
    );

    try {
      final result = await scanner.scan(
        absPath,
        onEntry: (entry) {
          // Offset depth when merging into parent scan
          final adjusted = depthOffset > 0
              ? FileEntry(
                  path: entry.path,
                  isDirectory: entry.isDirectory,
                  size: entry.size,
                  depth: entry.depth + depthOffset,
                  parentPath: entry.parentPath,
                )
              : entry;
          writer.add(adjusted);

          // Periodically update scan totals (every 10s)
          final now = DateTime.now();
          if (now.difference(lastSaveTime).inSeconds >= 10) {
            lastSaveTime = now;
            writer.flush();
          }
        },
        onProgress: (progress) {
          final elapsed = stopwatch.elapsed;
          final elapsedStr = _formatElapsed(elapsed);
          final sizeStr = SizeFormatter.format(progress.bytesScanned);
          final dir = p.basename(p.dirname(progress.currentPath));
          final hlInfo = progress.hardlinksSkipped > 0
              ? ', ${progress.hardlinksSkipped} hardlinks'
              : '';
          stdout.write(
            '\r  🔍 Scanning [$elapsedStr] '
            '${progress.filesScanned} files, '
            '${progress.dirsScanned} dirs, '
            '$sizeStr$hlInfo '
            '· ../$dir${' ' * 20}',
          );
        },
      );

      stopwatch.stop();

      // Flush remaining entries
      writer.dispose();

      // Update root entry size
      db.updateEntrySize(scanId, absPath, result.totalSize);

      if (merging) {
        // Recalculate ancestor directory sizes up to the parent scan root
        db.recalculateAncestorSizes(scanId, absPath, parentScan.rootPath);
        // Recompute parent scan totals from entries
        db.recomputeScanTotals(scanId);
      } else {
        // Mark scan as complete or interrupted
        final status = result.timedOut ? 'interrupted' : 'complete';
        db.updateScan(
          scanId: scanId,
          totalSize: result.totalSize,
          fileCount: result.fileCount,
          dirCount: result.dirCount,
          status: status,
        );
      }

      final status = result.timedOut ? 'interrupted' : 'complete';
      if (result.timedOut) {
        stdout.writeln(
          '\r  ⏱️  Scan timed out after ${_formatElapsed(stopwatch.elapsed)}${' ' * 30}',
        );
        stdout.writeln('  Partial results have been saved.');
      } else {
        stdout.writeln('\r  ✅ Scan complete!${' ' * 60}');
      }

      stdout.writeln('');
      stdout.writeln('  📊 Summary');
      stdout.writeln('  ${'─' * 40}');
      stdout.writeln('  Path:        $absPath');
      stdout.writeln(
        '  Total size:  ${SizeFormatter.format(result.totalSize)}',
      );
      stdout.writeln('  Files:       ${result.fileCount}');
      stdout.writeln('  Directories: ${result.dirCount}');
      stdout.writeln('  Time:        ${_formatElapsed(stopwatch.elapsed)}');
      stdout.writeln('  Scan ID:     $scanId');
      stdout.writeln('  Status:      $status');
      stdout.writeln('  DB writes:   ${writer.totalWritten} entries');
      if (merging) {
        stdout.writeln('  Merged into: ${parentScan.rootPath}');
      }
      if (result.hardlinksSkipped > 0) {
        stdout.writeln(
          '  Hardlinks:   ${result.hardlinksSkipped} duplicates skipped',
        );
      }
      if (result.errors.isNotEmpty) {
        stdout.writeln('  Errors:      ${result.errors.length}');
        for (final error in result.errors.take(5)) {
          stderr.writeln('    ⚠️  $error');
        }
        if (result.errors.length > 5) {
          stderr.writeln('    ... and ${result.errors.length - 5} more');
        }
      }
      stdout.writeln('');
    } catch (e) {
      // On any error (including Ctrl+C via ProcessSignal), save what we have
      writer.dispose();
      if (!merging) {
        db.updateScan(
          scanId: scanId,
          totalSize: 0,
          fileCount: 0,
          dirCount: 0,
          status: 'interrupted',
        );
      }
      stderr.writeln(
        '\r  ⚠️  Scan interrupted. Partial results saved (scan #$scanId).${' ' * 20}',
      );
      rethrow;
    } finally {
      db.close();
    }
  }

  Duration? _parseDuration(String input) {
    final regex = RegExp(r'^(\d+)\s*(s|m|h)$', caseSensitive: false);
    final match = regex.firstMatch(input.trim());
    if (match == null) return null;
    final value = int.parse(match.group(1)!);
    return switch (match.group(2)!.toLowerCase()) {
      's' => Duration(seconds: value),
      'm' => Duration(minutes: value),
      'h' => Duration(hours: value),
      _ => null,
    };
  }

  String _formatElapsed(Duration d) {
    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes.remainder(60)}m ${d.inSeconds.remainder(60)}s';
    } else if (d.inMinutes > 0) {
      return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    } else if (d.inSeconds > 0) {
      return '${d.inSeconds}.${(d.inMilliseconds.remainder(1000) ~/ 100)}s';
    }
    return '${d.inMilliseconds}ms';
  }
}
