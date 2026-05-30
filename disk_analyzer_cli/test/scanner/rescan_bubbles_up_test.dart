import 'dart:io';

import 'package:disk_analyzer_cli/src/scanner/disk_scanner.dart';
import 'package:disk_analyzer_cli/src/storage/database.dart';
import 'package:disk_analyzer_cli/src/storage/models.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// End-to-end regression for re-scan size propagation.
///
/// Builds a real directory tree on disk, scans it into the DB (mirroring
/// [ScanCommand]), then re-scans a nested subfolder (mirroring the scan
/// worker) and asserts the size change bubbles up through every ancestor to
/// the scan root.
void main() {
  late Directory tempDir;
  late DiskDatabase db;
  late String rootPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('disk_analyzer_rescan');
    db = DiskDatabase.open(p.join(tempDir.path, 'cache.db'));
    // The scanner walks from the symlink-resolved root and emits entries with
    // that resolved prefix, so model the stored tree against the same path.
    rootPath = tempDir.resolveSymbolicLinksSync();
  });

  tearDown(() {
    db.close();
    tempDir.deleteSync(recursive: true);
  });

  void writeFile(String relPath, int bytes) {
    final f = File(p.join(tempDir.path, relPath));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(List.filled(bytes, 0));
  }

  /// Scans [absPath] into [scanId], merging at [depthOffset] under [parent].
  /// Mirrors the delete -> insert -> finalize sequence used by the app.
  Future<int> scanInto(
    int scanId,
    String absPath, {
    required int depthOffset,
    String? parentOfRoot,
    required String aggregateRoot,
  }) async {
    db.deleteSubtree(scanId, absPath);
    final writer = db.batchWriter(scanId, batchSize: 1000);
    writer.add(FileEntry(
      path: absPath,
      isDirectory: true,
      size: 0,
      depth: depthOffset,
      parentPath: parentOfRoot,
    ));
    final scanner = DiskScanner();
    final result = await scanner.scan(
      absPath,
      onEntry: (e) => writer.add(FileEntry(
        path: e.path,
        isDirectory: e.isDirectory,
        size: e.size,
        depth: e.depth + depthOffset,
        parentPath: e.parentPath,
      )),
    );
    writer.dispose();
    db.updateEntrySize(scanId, absPath, result.totalSize);
    db.recalculateAncestorSizes(scanId, absPath, aggregateRoot);
    db.recomputeScanTotals(scanId);
    return result.totalSize;
  }

  /// Asserts that every directory's stored size equals the sum of its direct
  /// children, and that the root entry equals the scan total. This is exactly
  /// the "size bubbles up to the top" property.
  void expectTreeConsistent(int scanId) {
    final all = db.queryEntries(scanId: scanId);
    final byParent = <String?, List<FileEntry>>{};
    for (final e in all) {
      byParent.putIfAbsent(e.parentPath, () => []).add(e);
    }
    for (final e in all) {
      if (!e.isDirectory) continue;
      final children = byParent[e.path] ?? const [];
      final sum = children.fold<int>(0, (s, c) => s + c.size);
      expect(sum, e.size,
          reason: 'dir ${e.path} size ${e.size} != sum of children $sum');
    }
    final root = all.firstWhere((e) => e.parentPath == null);
    expect(db.getLatestScan(rootPath)!.totalSize, root.size,
        reason: 'scan total != root entry size');
  }

  test('re-scanning a nested subfolder bubbles a size change to the root',
      () async {
    // tree:
    //   root/a/b/deep.bin  (1000 bytes)
    //   root/a/sibling.bin (200 bytes)
    //   root/other.bin     (50 bytes)
    writeFile('a/b/deep.bin', 1000);
    writeFile('a/sibling.bin', 200);
    writeFile('other.bin', 50);

    final scanId = db.createScan(rootPath: rootPath);
    await scanInto(scanId, rootPath,
        depthOffset: 0, parentOfRoot: null, aggregateRoot: rootPath);
    expectTreeConsistent(scanId);

    final subPath = p.join(rootPath, 'a', 'b');
    final rootBefore = db.getEntry(scanId, rootPath)!.size;
    final aBefore = db.getEntry(scanId, p.join(rootPath, 'a'))!.size;
    final bBefore = db.getEntry(scanId, subPath)!.size;

    // Grow the deep file by ~9000 bytes, then re-scan only root/a/b.
    writeFile('a/b/deep.bin', 10000);

    final depthOffset = subPath.split('/').length - rootPath.split('/').length;
    await scanInto(scanId, subPath,
        depthOffset: depthOffset,
        parentOfRoot: p.dirname(subPath),
        aggregateRoot: rootPath);

    final bAfter = db.getEntry(scanId, subPath)!.size;
    final aAfter = db.getEntry(scanId, p.join(rootPath, 'a'))!.size;
    final rootAfter = db.getEntry(scanId, rootPath)!.size;

    final delta = bAfter - bBefore;
    expect(delta, greaterThan(0), reason: 'subfolder should have grown');
    // The same delta must propagate to every ancestor.
    expect(aAfter - aBefore, delta);
    expect(rootAfter - rootBefore, delta);
    expectTreeConsistent(scanId);
  });

  test('re-scanning a subfolder whose contents shrank bubbles up', () async {
    writeFile('a/b/deep.bin', 10000);
    writeFile('other.bin', 50);

    final scanId = db.createScan(rootPath: rootPath);
    await scanInto(scanId, rootPath,
        depthOffset: 0, parentOfRoot: null, aggregateRoot: rootPath);

    final subPath = p.join(rootPath, 'a', 'b');
    final bBefore = db.getEntry(scanId, subPath)!.size;
    final rootBefore = db.getEntry(scanId, rootPath)!.size;

    // Delete the big file, leaving the subfolder smaller.
    File(p.join(tempDir.path, 'a', 'b', 'deep.bin')).deleteSync();
    writeFile('a/b/tiny.bin', 1);

    final depthOffset = subPath.split('/').length - rootPath.split('/').length;
    await scanInto(scanId, subPath,
        depthOffset: depthOffset,
        parentOfRoot: p.dirname(subPath),
        aggregateRoot: rootPath);

    final bAfter = db.getEntry(scanId, subPath)!.size;
    final rootAfter = db.getEntry(scanId, rootPath)!.size;

    expect(bAfter, lessThan(bBefore));
    expect(rootAfter - rootBefore, bAfter - bBefore);
    expectTreeConsistent(scanId);
  });
}
