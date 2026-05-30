import 'dart:io';

import 'package:disk_analyzer_cli/src/storage/database.dart';
import 'package:disk_analyzer_cli/src/storage/models.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late DiskDatabase db;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('disk_analyzer_test');
    db = DiskDatabase.open(p.join(tempDir.path, 'cache.db'));
  });

  tearDown(() {
    db.close();
    tempDir.deleteSync(recursive: true);
  });

  /// Helper: builds a scan tree and returns the scan id.
  ///
  /// Tree (sizes in bytes):
  ///   /root                 (root)
  ///     /root/a             dir
  ///       /root/a/b         dir
  ///         /root/a/b/f1    file  100
  ///       /root/a/f2        file   50
  ///     /root/c             dir
  ///       /root/c/f3        file   30
  int buildTree() {
    final scanId = db.createScan(rootPath: '/root');
    final writer = db.batchWriter(scanId, batchSize: 100);
    writer.add(FileEntry(
        path: '/root', isDirectory: true, size: 180, depth: 0));
    writer.add(FileEntry(
        path: '/root/a',
        isDirectory: true,
        size: 150,
        depth: 1,
        parentPath: '/root'));
    writer.add(FileEntry(
        path: '/root/a/b',
        isDirectory: true,
        size: 100,
        depth: 2,
        parentPath: '/root/a'));
    writer.add(FileEntry(
        path: '/root/a/b/f1',
        isDirectory: false,
        size: 100,
        depth: 3,
        parentPath: '/root/a/b'));
    writer.add(FileEntry(
        path: '/root/a/f2',
        isDirectory: false,
        size: 50,
        depth: 2,
        parentPath: '/root/a'));
    writer.add(FileEntry(
        path: '/root/c',
        isDirectory: true,
        size: 30,
        depth: 1,
        parentPath: '/root'));
    writer.add(FileEntry(
        path: '/root/c/f3',
        isDirectory: false,
        size: 30,
        depth: 2,
        parentPath: '/root/c'));
    writer.dispose();
    db.updateScan(
        scanId: scanId,
        totalSize: 180,
        fileCount: 3,
        dirCount: 3,
        status: 'complete');
    return scanId;
  }

  int sizeOf(int scanId, String path) => db.getEntry(scanId, path)!.size;

  group('recalculateAncestorSizes', () {
    test('bubbles a deep subfolder size increase up to the root', () {
      final scanId = buildTree();

      // Re-scan /root/a/b: f1 grew from 100 -> 500.
      db.deleteSubtree(scanId, '/root/a/b');
      final writer = db.batchWriter(scanId, batchSize: 100);
      writer.add(FileEntry(
          path: '/root/a/b',
          isDirectory: true,
          size: 0,
          depth: 2,
          parentPath: '/root/a'));
      writer.add(FileEntry(
          path: '/root/a/b/f1',
          isDirectory: false,
          size: 500,
          depth: 3,
          parentPath: '/root/a/b'));
      writer.dispose();

      db.updateEntrySize(scanId, '/root/a/b', 500);
      db.recalculateAncestorSizes(scanId, '/root/a/b', '/root');
      db.recomputeScanTotals(scanId);

      expect(sizeOf(scanId, '/root/a/b'), 500);
      // /root/a = b(500) + f2(50)
      expect(sizeOf(scanId, '/root/a'), 550);
      // /root = a(550) + c(30)
      expect(sizeOf(scanId, '/root'), 580);
      // unaffected sibling stays put
      expect(sizeOf(scanId, '/root/c'), 30);

      final scan = db.getLatestScan('/root')!;
      expect(scan.totalSize, 580);
    });

    test('bubbles a subfolder size decrease up to the root', () {
      final scanId = buildTree();

      // Re-scan /root/a/b: f1 shrank from 100 -> 10.
      db.deleteSubtree(scanId, '/root/a/b');
      final writer = db.batchWriter(scanId, batchSize: 100);
      writer.add(FileEntry(
          path: '/root/a/b',
          isDirectory: true,
          size: 0,
          depth: 2,
          parentPath: '/root/a'));
      writer.add(FileEntry(
          path: '/root/a/b/f1',
          isDirectory: false,
          size: 10,
          depth: 3,
          parentPath: '/root/a/b'));
      writer.dispose();

      db.updateEntrySize(scanId, '/root/a/b', 10);
      db.recalculateAncestorSizes(scanId, '/root/a/b', '/root');
      db.recomputeScanTotals(scanId);

      expect(sizeOf(scanId, '/root/a/b'), 10);
      expect(sizeOf(scanId, '/root/a'), 60); // 10 + 50
      expect(sizeOf(scanId, '/root'), 90); // 60 + 30
      expect(db.getLatestScan('/root')!.totalSize, 90);
    });

    test('handles re-scan that empties a subfolder', () {
      final scanId = buildTree();

      db.deleteSubtree(scanId, '/root/a/b');
      final writer = db.batchWriter(scanId, batchSize: 100);
      // Subfolder now has no children at all.
      writer.add(FileEntry(
          path: '/root/a/b',
          isDirectory: true,
          size: 0,
          depth: 2,
          parentPath: '/root/a'));
      writer.dispose();

      db.updateEntrySize(scanId, '/root/a/b', 0);
      db.recalculateAncestorSizes(scanId, '/root/a/b', '/root');
      db.recomputeScanTotals(scanId);

      expect(sizeOf(scanId, '/root/a/b'), 0);
      expect(sizeOf(scanId, '/root/a'), 50); // only f2
      expect(sizeOf(scanId, '/root'), 80); // 50 + 30
    });

    test('re-scanning a direct child of root bubbles to root', () {
      final scanId = buildTree();

      // Re-scan /root/c: f3 grew 30 -> 300.
      db.deleteSubtree(scanId, '/root/c');
      final writer = db.batchWriter(scanId, batchSize: 100);
      writer.add(FileEntry(
          path: '/root/c',
          isDirectory: true,
          size: 0,
          depth: 1,
          parentPath: '/root'));
      writer.add(FileEntry(
          path: '/root/c/f3',
          isDirectory: false,
          size: 300,
          depth: 2,
          parentPath: '/root/c'));
      writer.dispose();

      db.updateEntrySize(scanId, '/root/c', 300);
      db.recalculateAncestorSizes(scanId, '/root/c', '/root');
      db.recomputeScanTotals(scanId);

      expect(sizeOf(scanId, '/root/c'), 300);
      expect(sizeOf(scanId, '/root/a'), 150); // unchanged
      expect(sizeOf(scanId, '/root'), 450); // 150 + 300
    });
  });
}
