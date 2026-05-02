import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../display/size_formatter.dart';
import '../display/tree_renderer.dart';
import '../storage/database.dart';

/// Visualizes cached disk usage data as a tree.
class ShowCommand extends Command<void> {
  @override
  final name = 'show';

  @override
  final description = 'Show disk usage from cached scan data.';

  ShowCommand() {
    argParser
      ..addOption(
        'depth',
        abbr: 'd',
        help: 'Maximum depth to display.',
        valueHelp: 'N',
        defaultsTo: '1',
      )
      ..addOption(
        'sort',
        abbr: 's',
        help: 'Sort entries by.',
        allowed: ['size', 'name'],
        defaultsTo: 'size',
      )
      ..addOption(
        'top',
        abbr: 't',
        help: 'Show only the top N entries per level.',
        valueHelp: 'N',
      )
      ..addOption(
        'min-size',
        help: 'Only show entries larger than this size (e.g., 1MB, 100KB).',
        valueHelp: 'SIZE',
      )
      ..addFlag(
        'dirs-only',
        help: 'Show only directories.',
        defaultsTo: false,
      )
      ..addFlag(
        'all',
        abbr: 'a',
        help: 'Show all cached scans.',
        defaultsTo: false,
      );
  }

  @override
  Future<void> run() async {
    final db = DiskDatabase.open();
    try {
      if (argResults!.flag('all')) {
        _showAllScans(db);
        return;
      }

      final rest = argResults!.rest;
      final targetPath = rest.isEmpty ? Directory.current.path : rest.first;
      final absPath = p.canonicalize(targetPath);

      // Find the relevant scan
      var scan = db.getLatestScan(absPath);
      scan ??= db.findScanContaining(absPath);

      if (scan == null) {
        stderr.writeln('No cached scan data found for: $absPath');
        stderr.writeln('Run `disk_analyzer_cli scan $absPath` first.');
        return;
      }

      final depthStr = argResults!.option('depth')!;
      final maxDisplayDepth = int.parse(depthStr);
      final sortBy = argResults!.option('sort')!;
      final topStr = argResults!.option('top');
      final top = topStr != null ? int.parse(topStr) : null;
      final minSizeStr = argResults!.option('min-size');
      final minSize = minSizeStr != null ? SizeFormatter.parse(minSizeStr) : null;
      final dirsOnly = argResults!.flag('dirs-only');

      // Get the root entry for the target path
      final rootEntry = db.getEntry(scan.id, absPath);
      final totalSize = rootEntry?.size ?? scan.totalSize;

      stdout.write(TreeRenderer.renderHeader(
        rootPath: absPath,
        totalSize: totalSize,
        fileCount: scan.fileCount,
        dirCount: scan.dirCount,
        scannedAt: scan.scannedAt,
      ));

      if (scan.isPartial) {
        stdout.writeln('  ⚠️  This scan is ${scan.status} — results may be incomplete.');
        stdout.writeln('');
      }

      // Recursively display the tree
      _printLevel(
        db: db,
        scanId: scan.id,
        parentPath: absPath,
        totalSize: totalSize,
        currentDepth: 0,
        maxDepth: maxDisplayDepth,
        sortBy: sortBy,
        top: top,
        minSize: minSize,
        dirsOnly: dirsOnly,
      );
    } finally {
      db.close();
    }
  }

  void _printLevel({
    required DiskDatabase db,
    required int scanId,
    required String parentPath,
    required int totalSize,
    required int currentDepth,
    required int maxDepth,
    required String sortBy,
    int? top,
    int? minSize,
    required bool dirsOnly,
  }) {
    if (currentDepth >= maxDepth) return;

    final entries = db.queryEntries(
      scanId: scanId,
      parentPath: parentPath,
      sortBy: sortBy,
      directoriesOnly: dirsOnly,
      minSize: minSize,
      limit: top,
    );

    // Filter to only direct children
    final directChildren = entries
        .where((e) => e.parentPath == parentPath)
        .toList();

    if (directChildren.isEmpty) return;

    stdout.write(TreeRenderer.renderTree(
      entries: directChildren,
      totalSize: totalSize,
      indent: currentDepth,
      maxItems: top,
    ));

    // Recurse into subdirectories
    if (currentDepth + 1 < maxDepth) {
      for (final entry in directChildren) {
        if (entry.isDirectory) {
          _printLevel(
            db: db,
            scanId: scanId,
            parentPath: entry.path,
            totalSize: totalSize,
            currentDepth: currentDepth + 1,
            maxDepth: maxDepth,
            sortBy: sortBy,
            top: top,
            minSize: minSize,
            dirsOnly: dirsOnly,
          );
        }
      }
    }
  }

  void _showAllScans(DiskDatabase db) {
    final scans = db.getAllScans();
    if (scans.isEmpty) {
      stdout.writeln('No cached scans found.');
      return;
    }

    stdout.writeln('');
    stdout.writeln('  📋 Cached Scans');
    stdout.writeln('  ${'─' * 60}');
    for (final scan in scans) {
      final statusIcon = switch (scan.status) {
        'complete' => '✅',
        'scanning' => '🔄',
        'interrupted' => '⚠️',
        _ => '❓',
      };
      stdout.writeln(
        '  $statusIcon #${scan.id.toString().padLeft(3)}  '
        '${SizeFormatter.format(scan.totalSize).padLeft(10)}  '
        '${scan.rootPath}  '
        '(${_formatDate(scan.scannedAt)})',
      );
    }
    stdout.writeln('');
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)} '
        '${_pad(dt.hour)}:${_pad(dt.minute)}';
  }

  String _pad(int n) => n.toString().padLeft(2, '0');
}
