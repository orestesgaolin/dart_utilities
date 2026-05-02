import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'models.dart';

/// SQLite database wrapper for caching disk scan results.
class DiskDatabase {
  late final Database _db;
  final String dbPath;

  DiskDatabase._(this.dbPath);

  /// Open (or create) the database at the default cache location.
  /// Set [skipMigrations] to true for worker isolates where schema is
  /// already initialized by the main isolate.
  factory DiskDatabase.open([String? path, bool skipMigrations = false]) {
    final dbPath = path ?? _defaultDbPath();
    final dir = Directory(p.dirname(dbPath));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final db = DiskDatabase._(dbPath);
    db._db = sqlite3.open(dbPath);
    if (skipMigrations) {
      db._initPragmas();
    } else {
      db._initSchema();
    }
    return db;
  }

  static String _defaultDbPath() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return p.join(home, '.disk_cleaner', 'cache.db');
  }

  /// Set only runtime pragmas (for worker isolates).
  void _initPragmas() {
    _db.execute('PRAGMA journal_mode=WAL');
    _db.execute('PRAGMA busy_timeout=5000');
    _db.execute('PRAGMA foreign_keys=ON');
  }

  void _initSchema() {
    _db.execute('PRAGMA journal_mode=WAL');
    _db.execute('PRAGMA foreign_keys=ON');
    _db.execute('PRAGMA busy_timeout=5000');

    // Check schema version for migrations
    final version =
        _db.select('PRAGMA user_version').first.values.first as int;

    if (version == 0) {
      // Check if old schema exists (has 'name' column in entries)
      final hasOldSchema = _db
          .select("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='entries'")
          .first
          .values
          .first as int;

      if (hasOldSchema > 0) {
        _migrateToV1();
      } else {
        _createSchemaV1();
      }
      _db.execute('PRAGMA user_version = 1');
    }
  }

  void _createSchemaV1() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS scans (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        root_path TEXT NOT NULL,
        scanned_at TEXT NOT NULL,
        total_size INTEGER NOT NULL DEFAULT 0,
        file_count INTEGER NOT NULL DEFAULT 0,
        dir_count INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'scanning'
      )
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS entries (
        scan_id INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
        path TEXT NOT NULL,
        is_directory INTEGER NOT NULL,
        size INTEGER NOT NULL,
        depth INTEGER NOT NULL,
        parent_path TEXT,
        PRIMARY KEY(scan_id, path)
      ) WITHOUT ROWID
    ''');
    _db.execute(
        'CREATE INDEX IF NOT EXISTS idx_entries_scan_parent ON entries(scan_id, parent_path)');
  }

  void _migrateToV1() {
    // Check if we have the old 'name' column (pre-v1 schema)
    final cols = _db.select("PRAGMA table_info('entries')");
    final hasNameCol = cols.any((r) => r['name'] == 'name');

    if (!hasNameCol) {
      // Already on new schema, just ensure indexes are right
      return;
    }

    // Rebuild entries table: drop name column, id column, use WITHOUT ROWID
    _db.execute('BEGIN TRANSACTION');
    try {
      _db.execute('''
        CREATE TABLE entries_new (
          scan_id INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
          path TEXT NOT NULL,
          is_directory INTEGER NOT NULL,
          size INTEGER NOT NULL,
          depth INTEGER NOT NULL,
          parent_path TEXT,
          PRIMARY KEY(scan_id, path)
        ) WITHOUT ROWID
      ''');
      _db.execute('''
        INSERT INTO entries_new (scan_id, path, is_directory, size, depth, parent_path)
        SELECT scan_id, path, is_directory, size, depth, parent_path FROM entries
      ''');
      _db.execute('DROP TABLE entries');
      _db.execute('ALTER TABLE entries_new RENAME TO entries');

      // Drop all old indexes and create only the one we need
      _db.execute(
          'CREATE INDEX IF NOT EXISTS idx_entries_scan_parent ON entries(scan_id, parent_path)');

      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Create a new scan record upfront (status='scanning') and return its ID.
  int createScan({required String rootPath}) {
    // Remove previous scans for same root to avoid duplicates
    _db.execute(
      'DELETE FROM entries WHERE scan_id IN '
      '(SELECT id FROM scans WHERE root_path = ?)',
      [rootPath],
    );
    _db.execute('DELETE FROM scans WHERE root_path = ?', [rootPath]);

    _db.execute(
      'INSERT INTO scans (root_path, scanned_at, total_size, file_count, dir_count, status) '
      'VALUES (?, ?, 0, 0, 0, \'scanning\')',
      [rootPath, DateTime.now().toIso8601String()],
    );
    return _db.lastInsertRowId;
  }

  /// Update scan totals and status.
  void updateScan({
    required int scanId,
    required int totalSize,
    required int fileCount,
    required int dirCount,
    required String status,
  }) {
    _db.execute(
      'UPDATE scans SET total_size = ?, file_count = ?, dir_count = ?, status = ? '
      'WHERE id = ?',
      [totalSize, fileCount, dirCount, status, scanId],
    );
  }

  /// Create a [BatchWriter] for efficient streaming inserts.
  BatchWriter batchWriter(int scanId, {int batchSize = 5000}) {
    return BatchWriter._(_db, scanId, batchSize: batchSize);
  }

  /// Get the latest scan for a given root path.
  ScanRecord? getLatestScan(String rootPath) {
    final result = _db.select(
      'SELECT id, root_path, scanned_at, total_size, file_count, dir_count, status FROM scans '
      'WHERE root_path = ? ORDER BY scanned_at DESC LIMIT 1',
      [rootPath],
    );
    if (result.isEmpty) return null;
    return _rowToScan(result.first);
  }

  /// Find the scan whose root path contains the given path.
  ScanRecord? findScanContaining(String path) {
    final result = _db.select(
      'SELECT id, root_path, scanned_at, total_size, file_count, dir_count, status FROM scans '
      'WHERE ? LIKE root_path || \'%\' '
      'ORDER BY length(root_path) DESC, scanned_at DESC LIMIT 1',
      [path],
    );
    if (result.isEmpty) return null;
    return _rowToScan(result.first);
  }

  /// Get all scans.
  List<ScanRecord> getAllScans() {
    final result = _db.select(
      'SELECT id, root_path, scanned_at, total_size, file_count, dir_count, status '
      'FROM scans ORDER BY scanned_at DESC',
    );
    return result.map(_rowToScan).toList();
  }

  ScanRecord _rowToScan(Row row) {
    return ScanRecord(
      id: row['id'] as int,
      rootPath: row['root_path'] as String,
      scannedAt: DateTime.parse(row['scanned_at'] as String),
      totalSize: row['total_size'] as int,
      fileCount: row['file_count'] as int,
      dirCount: row['dir_count'] as int,
      status: row['status'] as String,
    );
  }

  /// Query entries for a scan, optionally filtered.
  List<FileEntry> queryEntries({
    required int scanId,
    String? parentPath,
    int? maxDepth,
    bool? directoriesOnly,
    String sortBy = 'size',
    bool descending = true,
    int? limit,
    int? minSize,
  }) {
    final conditions = ['scan_id = ?'];
    final params = <Object>[scanId];

    if (parentPath != null) {
      conditions.add('parent_path = ?');
      params.add(parentPath);
    }
    if (maxDepth != null) {
      conditions.add('depth <= ?');
      params.add(maxDepth);
    }
    if (directoriesOnly == true) {
      conditions.add('is_directory = 1');
    }
    if (minSize != null) {
      conditions.add('size >= ?');
      params.add(minSize);
    }

    final orderDir = descending ? 'DESC' : 'ASC';
    final orderCol = sortBy == 'name'
        ? "substr(path, length(rtrim(path, replace(path, '/', ''))) + 1)"
        : 'size';
    var query = 'SELECT path, is_directory, size, depth, parent_path '
        'FROM entries WHERE ${conditions.join(' AND ')} '
        'ORDER BY is_directory DESC, $orderCol $orderDir';
    if (limit != null) {
      query += ' LIMIT $limit';
    }

    final result = _db.select(query, params);
    return result.map((row) => FileEntry(
      path: row['path'] as String,
      isDirectory: (row['is_directory'] as int) == 1,
      size: row['size'] as int,
      depth: row['depth'] as int,
      parentPath: row['parent_path'] as String?,
    )).toList();
  }

  /// Get a specific entry by path.
  FileEntry? getEntry(int scanId, String path) {
    final result = _db.select(
      'SELECT path, is_directory, size, depth, parent_path '
      'FROM entries WHERE scan_id = ? AND path = ?',
      [scanId, path],
    );
    if (result.isEmpty) return null;
    final row = result.first;
    return FileEntry(
      path: row['path'] as String,
      isDirectory: (row['is_directory'] as int) == 1,
      size: row['size'] as int,
      depth: row['depth'] as int,
      parentPath: row['parent_path'] as String?,
    );
  }

  /// Find a parent scan that contains the given path (strict parent, not exact match).
  ScanRecord? findParentScan(String path) {
    // Match scans where path starts with root_path + '/'
    final result = _db.select(
      'SELECT id, root_path, scanned_at, total_size, file_count, dir_count, status FROM scans '
      'WHERE root_path != ? AND substr(?, 1, length(root_path) + 1) = root_path || \'/\' '
      'ORDER BY length(root_path) DESC, scanned_at DESC LIMIT 1',
      [path, path],
    );
    if (result.isEmpty) return null;
    return _rowToScan(result.first);
  }

  /// Delete all entries under a subtree path within a scan (inclusive).
  /// Uses exact path match + path prefix with '/' boundary to avoid prefix collisions.
  void deleteSubtree(int scanId, String subtreePath) {
    _db.execute(
      'DELETE FROM entries WHERE scan_id = ? AND (path = ? OR path LIKE ? || \'/%\')',
      [scanId, subtreePath, subtreePath],
    );
  }

  /// Get the depth of an entry in a scan.
  int? getEntryDepth(int scanId, String path) {
    final result = _db.select(
      'SELECT depth FROM entries WHERE scan_id = ? AND path = ?',
      [scanId, path],
    );
    if (result.isEmpty) return null;
    return result.first['depth'] as int;
  }

  /// Recalculate directory sizes from the given path up to the scan root.
  /// Each directory's size = SUM of its direct children's sizes.
  void recalculateAncestorSizes(int scanId, String fromPath, String rootPath) {
    var current = fromPath;
    while (current != rootPath && current.isNotEmpty) {
      final parent = p.dirname(current);
      // Recalculate parent's size from direct children
      final result = _db.select(
        'SELECT COALESCE(SUM(size), 0) as total FROM entries '
        'WHERE scan_id = ? AND parent_path = ?',
        [scanId, parent],
      );
      final newSize = result.first['total'] as int;
      _db.execute(
        'UPDATE entries SET size = ? WHERE scan_id = ? AND path = ?',
        [newSize, scanId, parent],
      );
      current = parent;
    }
  }

  /// Recompute scan totals from entries.
  void recomputeScanTotals(int scanId) {
    final rootEntry = _db.select(
      'SELECT path, size FROM entries WHERE scan_id = ? AND parent_path IS NULL LIMIT 1',
      [scanId],
    );
    final totalSize = rootEntry.isNotEmpty ? rootEntry.first['size'] as int : 0;

    final counts = _db.select(
      'SELECT '
      'SUM(CASE WHEN is_directory = 0 THEN 1 ELSE 0 END) as file_count, '
      'SUM(CASE WHEN is_directory = 1 THEN 1 ELSE 0 END) - 1 as dir_count '
      'FROM entries WHERE scan_id = ?',
      [scanId],
    );
    final fileCount = (counts.first['file_count'] as int?) ?? 0;
    final dirCount = (counts.first['dir_count'] as int?) ?? 0;

    _db.execute(
      'UPDATE scans SET total_size = ?, file_count = ?, dir_count = ?, '
      'scanned_at = ? WHERE id = ?',
      [totalSize, fileCount, dirCount.clamp(0, dirCount),
       DateTime.now().toIso8601String(), scanId],
    );
  }

  /// Update the size of an existing entry.
  void updateEntrySize(int scanId, String path, int size) {
    _db.execute(
      'UPDATE entries SET size = ? WHERE scan_id = ? AND path = ?',
      [size, scanId, path],
    );
  }

  /// Insert a single entry (or ignore if it already exists).
  void insertEntry(int scanId, FileEntry entry) {
    _db.execute(
      'INSERT OR IGNORE INTO entries (scan_id, path, is_directory, size, depth, parent_path) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [
        scanId,
        entry.path,
        entry.isDirectory ? 1 : 0,
        entry.size,
        entry.depth,
        entry.parentPath,
      ],
    );
  }

  /// Delete a single entry by path.
  void deleteEntry(int scanId, String path) {
    _db.execute(
      'DELETE FROM entries WHERE scan_id = ? AND path = ?',
      [scanId, path],
    );
  }

  /// Delete a scan and all its entries.
  void deleteScan(int scanId) {
    _db.execute('DELETE FROM entries WHERE scan_id = ?', [scanId]);
    _db.execute('DELETE FROM scans WHERE id = ?', [scanId]);
    _db.execute('VACUUM');
  }

  /// Delete all scans for a given root path.
  void deleteScansForPath(String rootPath) {
    _db.execute(
      'DELETE FROM entries WHERE scan_id IN '
      '(SELECT id FROM scans WHERE root_path = ?)',
      [rootPath],
    );
    _db.execute('DELETE FROM scans WHERE root_path = ?', [rootPath]);
    _db.execute('VACUUM');
  }

  /// Delete all cached data.
  void deleteAll() {
    _db.execute('DELETE FROM entries');
    _db.execute('DELETE FROM scans');
    _db.execute('VACUUM');
  }

  void close() {
    _db.close();
  }
}

/// Efficiently writes entries to SQLite in batches.
///
/// Accumulates entries in memory and flushes to DB every [batchSize] entries.
/// Call [flush] when done to write remaining entries.
class BatchWriter {
  final Database _db;
  final int scanId;
  final int batchSize;

  final _buffer = <FileEntry>[];
  late final PreparedStatement _stmt;
  int _totalWritten = 0;

  BatchWriter._(this._db, this.scanId, {this.batchSize = 5000}) {
    _stmt = _db.prepare(
      'INSERT OR IGNORE INTO entries (scan_id, path, is_directory, size, depth, parent_path) '
      'VALUES (?, ?, ?, ?, ?, ?)',
    );
  }

  int get totalWritten => _totalWritten;

  /// Add an entry to the buffer; flushes automatically when buffer is full.
  void add(FileEntry entry) {
    _buffer.add(entry);
    if (_buffer.length >= batchSize) {
      flush();
    }
  }

  /// Write all buffered entries to the database.
  void flush() {
    if (_buffer.isEmpty) return;
    _db.execute('BEGIN TRANSACTION');
    try {
      for (final entry in _buffer) {
        _stmt.execute([
          scanId,
          entry.path,
          entry.isDirectory ? 1 : 0,
          entry.size,
          entry.depth,
          entry.parentPath,
        ]);
      }
      _db.execute('COMMIT');
      _totalWritten += _buffer.length;
      _buffer.clear();
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Flush remaining entries and release the prepared statement.
  void dispose() {
    flush();
    _stmt.close();
  }
}
