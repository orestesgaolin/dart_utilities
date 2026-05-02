import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../storage/database.dart';
import '../storage/models.dart';
import 'disk_scanner.dart';

/// Configuration sent to the scan worker isolate.
class ScanWorkerConfig {
  final SendPort sendPort;
  final String dbPath;
  final String targetPath;
  final int scanId;
  final String rootPath;
  final int depthOffset;

  ScanWorkerConfig({
    required this.sendPort,
    required this.dbPath,
    required this.targetPath,
    required this.scanId,
    required this.rootPath,
    required this.depthOffset,
  });
}

/// Messages sent from the worker to the main isolate.
sealed class ScanWorkerMessage {}

class ScanWorkerProgress extends ScanWorkerMessage {
  final int filesScanned;
  final int bytesScanned;
  ScanWorkerProgress({required this.filesScanned, required this.bytesScanned});
}

class ScanWorkerDone extends ScanWorkerMessage {
  final int totalSize;
  final int fileCount;
  ScanWorkerDone({required this.totalSize, required this.fileCount});
}

class ScanWorkerError extends ScanWorkerMessage {
  final String message;
  ScanWorkerError(this.message);
}

/// Entry point for the scan worker isolate.
///
/// Opens its own DB connection, runs the full scan (delete old subtree,
/// insert entries, finalize sizes), and sends progress back via SendPort.
@pragma('vm:entry-point')
Future<void> scanWorkerEntry(ScanWorkerConfig config) async {
  final sendPort = config.sendPort;

  DiskDatabase? db;
  try {
    // Open a separate DB connection (schema already initialized by main)
    db = DiskDatabase.open(config.dbPath, true);
    final scanId = config.scanId;
    final targetPath = config.targetPath;
    final rootPath = config.rootPath;
    final depthOffset = config.depthOffset;

    // Delete existing subtree in the worker (sole writer)
    db.deleteSubtree(scanId, targetPath);

    final writer = db.batchWriter(scanId);
    final scanner = DiskScanner();

    // Insert root entry for the scanned subfolder
    writer.add(FileEntry(
      path: targetPath,
      isDirectory: true,
      size: 0,
      depth: depthOffset,
      parentPath: p.dirname(targetPath),
    ));

    final result = await scanner.scan(
      targetPath,
      onEntry: (entry) {
        writer.add(FileEntry(
          path: entry.path,
          isDirectory: entry.isDirectory,
          size: entry.size,
          depth: entry.depth + depthOffset,
          parentPath: entry.parentPath,
        ));
      },
      onProgress: (progress) {
        sendPort.send(ScanWorkerProgress(
          filesScanned: progress.filesScanned,
          bytesScanned: progress.bytesScanned,
        ));
      },
    );

    // Flush remaining writes
    writer.dispose();

    // Finalize: update sizes and totals in one logical unit
    db.updateEntrySize(scanId, targetPath, result.totalSize);
    db.recalculateAncestorSizes(scanId, targetPath, rootPath);
    db.recomputeScanTotals(scanId);

    sendPort.send(ScanWorkerDone(
      totalSize: result.totalSize,
      fileCount: result.fileCount,
    ));
  } catch (e) {
    sendPort.send(ScanWorkerError(e.toString()));
  } finally {
    db?.close();
  }
}

/// Launches a scan in a background isolate.
///
/// Returns a [ScanWorkerHandle] that can be used to listen for progress
/// and completion.
Future<ScanWorkerHandle> launchScanWorker({
  required String dbPath,
  required String targetPath,
  required int scanId,
  required String rootPath,
  required int depthOffset,
}) async {
  final receivePort = ReceivePort();
  final errorPort = ReceivePort();
  final exitPort = ReceivePort();

  final config = ScanWorkerConfig(
    sendPort: receivePort.sendPort,
    dbPath: dbPath,
    targetPath: targetPath,
    scanId: scanId,
    rootPath: rootPath,
    depthOffset: depthOffset,
  );

  await Isolate.spawn(
    scanWorkerEntry,
    config,
    onError: errorPort.sendPort,
    onExit: exitPort.sendPort,
    debugName: 'scan-worker:${p.basename(targetPath)}',
  );

  return ScanWorkerHandle._(receivePort, errorPort, exitPort);
}

/// Handle to a running scan worker, providing a stream of messages.
class ScanWorkerHandle {
  final ReceivePort _receivePort;
  final ReceivePort _errorPort;
  final ReceivePort _exitPort;

  ScanWorkerHandle._(this._receivePort, this._errorPort, this._exitPort);

  /// Listen for worker messages. Calls [onProgress], [onDone], or [onError].
  /// Automatically cleans up ports when the worker exits.
  void listen({
    required void Function(ScanWorkerProgress) onProgress,
    required void Function(ScanWorkerDone) onDone,
    required void Function(String error) onError,
  }) {
    var completed = false;

    _receivePort.listen((message) {
      if (message is ScanWorkerProgress) {
        onProgress(message);
      } else if (message is ScanWorkerDone) {
        completed = true;
        onDone(message);
      } else if (message is ScanWorkerError) {
        completed = true;
        onError(message.message);
      }
    });

    _errorPort.listen((message) {
      if (!completed) {
        final errorMsg = message is List ? message.join(': ') : '$message';
        onError('Isolate error: $errorMsg');
        completed = true;
      }
    });

    _exitPort.listen((_) {
      if (!completed) {
        onError('Worker exited unexpectedly');
      }
      _dispose();
    });
  }

  void _dispose() {
    _receivePort.close();
    _errorPort.close();
    _exitPort.close();
  }
}
