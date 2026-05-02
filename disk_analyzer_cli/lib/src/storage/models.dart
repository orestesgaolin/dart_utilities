/// Data models for disk scanner entries.
class ScanRecord {
  final int id;
  final String rootPath;
  final DateTime scannedAt;
  final int totalSize;
  final int fileCount;
  final int dirCount;
  final String status; // 'scanning', 'complete', 'interrupted'

  ScanRecord({
    required this.id,
    required this.rootPath,
    required this.scannedAt,
    required this.totalSize,
    this.fileCount = 0,
    this.dirCount = 0,
    this.status = 'scanning',
  });

  bool get isComplete => status == 'complete';
  bool get isPartial => status != 'complete';
}

class FileEntry {
  final String path;
  final bool isDirectory;
  final int size;
  final int depth;
  final String? parentPath;

  /// Derived from [path] — no longer stored in the database.
  String get name {
    final idx = path.lastIndexOf('/');
    return idx < 0 ? path : path.substring(idx + 1);
  }

  FileEntry({
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.depth,
    this.parentPath,
  });
}
