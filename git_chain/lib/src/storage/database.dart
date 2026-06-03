import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../models.dart';

/// Persistent store for repositories, chains, and sync history.
///
/// Data lives in `~/.git_chain/git_chain.db` so chains and history are tracked
/// across every repository on the machine.
class ChainDatabase {
  ChainDatabase._(this._db, this.dbPath);

  final Database _db;
  final String dbPath;

  /// Default on-disk location of the database.
  static String defaultPath() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.current.path;
    return p.join(home, '.git_chain', 'git_chain.db');
  }

  /// Opens (creating if needed) the database and applies the schema.
  factory ChainDatabase.open([String? path]) {
    final dbPath = path ?? defaultPath();
    Directory(p.dirname(dbPath)).createSync(recursive: true);
    final db = sqlite3.open(dbPath);
    db.execute('PRAGMA foreign_keys = ON;');
    _migrate(db);
    return ChainDatabase._(db, dbPath);
  }

  static void _migrate(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS repos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        default_branch TEXT NOT NULL,
        remote_url TEXT,
        last_opened_at INTEGER
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS chains (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        repo_id INTEGER NOT NULL REFERENCES repos(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        target_branch TEXT NOT NULL,
        created_at INTEGER,
        updated_at INTEGER
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS chain_branches (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        chain_id INTEGER NOT NULL REFERENCES chains(id) ON DELETE CASCADE,
        position INTEGER NOT NULL,
        branch TEXT NOT NULL,
        pr_number INTEGER
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS sync_runs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        chain_id INTEGER NOT NULL REFERENCES chains(id) ON DELETE CASCADE,
        strategy TEXT NOT NULL,
        status TEXT NOT NULL,
        summary TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        finished_at INTEGER
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS sync_steps (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        run_id INTEGER NOT NULL REFERENCES sync_runs(id) ON DELETE CASCADE,
        position INTEGER NOT NULL,
        branch TEXT NOT NULL,
        parent TEXT NOT NULL,
        status TEXT NOT NULL,
        detail TEXT
      );
    ''');
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_chain_branches_chain ON chain_branches(chain_id);');
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sync_runs_chain ON sync_runs(chain_id);');
  }

  int _now() => DateTime.now().millisecondsSinceEpoch;

  DateTime? _date(Object? ms) =>
      ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms as int);

  // ---- Repos ----------------------------------------------------------------

  /// Inserts the repo if absent, otherwise refreshes its metadata, and returns
  /// the up-to-date [Repo] including its id.
  Repo upsertRepo({
    required String path,
    required String name,
    required String defaultBranch,
    String? remoteUrl,
  }) {
    final existing = _db.select('SELECT id FROM repos WHERE path = ?', [path]);
    if (existing.isEmpty) {
      _db.execute(
        'INSERT INTO repos (path, name, default_branch, remote_url, last_opened_at) VALUES (?, ?, ?, ?, ?)',
        [path, name, defaultBranch, remoteUrl, _now()],
      );
    } else {
      _db.execute(
        'UPDATE repos SET name = ?, default_branch = ?, remote_url = ?, last_opened_at = ? WHERE path = ?',
        [name, defaultBranch, remoteUrl, _now(), path],
      );
    }
    return getRepoByPath(path)!;
  }

  Repo? getRepoByPath(String path) {
    final rows = _db.select('SELECT * FROM repos WHERE path = ?', [path]);
    return rows.isEmpty ? null : _repoFromRow(rows.first);
  }

  Repo? getRepo(int id) {
    final rows = _db.select('SELECT * FROM repos WHERE id = ?', [id]);
    return rows.isEmpty ? null : _repoFromRow(rows.first);
  }

  /// All known repos, most recently opened first.
  List<Repo> listRepos() {
    final rows = _db.select(
        'SELECT * FROM repos ORDER BY last_opened_at DESC, name ASC');
    return rows.map(_repoFromRow).toList();
  }

  void touchRepo(int id) {
    _db.execute('UPDATE repos SET last_opened_at = ? WHERE id = ?', [_now(), id]);
  }

  void deleteRepo(int id) {
    _db.execute('DELETE FROM repos WHERE id = ?', [id]);
  }

  Repo _repoFromRow(Row row) => Repo(
        id: row['id'] as int,
        path: row['path'] as String,
        name: row['name'] as String,
        defaultBranch: row['default_branch'] as String,
        remoteUrl: row['remote_url'] as String?,
        lastOpenedAt: _date(row['last_opened_at']),
      );

  // ---- Chains ---------------------------------------------------------------

  List<Chain> listChains(int repoId) {
    // Stable order by creation so chains don't jump around between visits when
    // their PR annotations are refreshed.
    final rows = _db.select(
        'SELECT * FROM chains WHERE repo_id = ? ORDER BY created_at ASC, id ASC',
        [repoId]);
    return rows.map(_chainFromRow).toList();
  }

  Chain? getChain(int id) {
    final rows = _db.select('SELECT * FROM chains WHERE id = ?', [id]);
    return rows.isEmpty ? null : _chainFromRow(rows.first);
  }

  Chain _chainFromRow(Row row) {
    final id = row['id'] as int;
    final branchRows = _db.select(
        'SELECT * FROM chain_branches WHERE chain_id = ? ORDER BY position ASC',
        [id]);
    final branches = branchRows
        .map((b) => ChainBranch(
              branch: b['branch'] as String,
              position: b['position'] as int,
              prNumber: b['pr_number'] as int?,
            ))
        .toList();
    return Chain(
      id: id,
      repoId: row['repo_id'] as int,
      name: row['name'] as String,
      targetBranch: row['target_branch'] as String,
      branches: branches,
      createdAt: _date(row['created_at']),
      updatedAt: _date(row['updated_at']),
    );
  }

  /// Creates a chain (with its ordered branches) and returns it.
  Chain createChain({
    required int repoId,
    required String name,
    required String targetBranch,
    required List<ChainBranch> branches,
  }) {
    _db.execute(
      'INSERT INTO chains (repo_id, name, target_branch, created_at, updated_at) VALUES (?, ?, ?, ?, ?)',
      [repoId, name, targetBranch, _now(), _now()],
    );
    final chainId = _db.lastInsertRowId;
    _writeBranches(chainId, branches);
    return getChain(chainId)!;
  }

  /// Replaces the ordered branch list of [chainId].
  void updateChainBranches(int chainId, List<ChainBranch> branches) {
    _db.execute('DELETE FROM chain_branches WHERE chain_id = ?', [chainId]);
    _writeBranches(chainId, branches);
    _db.execute('UPDATE chains SET updated_at = ? WHERE id = ?', [_now(), chainId]);
  }

  void renameChain(int chainId, String name) {
    _db.execute('UPDATE chains SET name = ?, updated_at = ? WHERE id = ?',
        [name, _now(), chainId]);
  }

  void deleteChain(int chainId) {
    _db.execute('DELETE FROM chains WHERE id = ?', [chainId]);
  }

  void _writeBranches(int chainId, List<ChainBranch> branches) {
    final stmt = _db.prepare(
        'INSERT INTO chain_branches (chain_id, position, branch, pr_number) VALUES (?, ?, ?, ?)');
    try {
      for (var i = 0; i < branches.length; i++) {
        final b = branches[i];
        stmt.execute([chainId, i, b.branch, b.prNumber]);
      }
    } finally {
      stmt.close();
    }
  }

  // ---- Sync history ---------------------------------------------------------

  /// Records a completed sync run and its per-branch steps; returns run id.
  int recordSyncRun({
    required int chainId,
    required SyncStrategy strategy,
    required String status,
    required String summary,
    required DateTime startedAt,
    required DateTime finishedAt,
    required List<SyncStepResult> steps,
  }) {
    _db.execute(
      'INSERT INTO sync_runs (chain_id, strategy, status, summary, started_at, finished_at) VALUES (?, ?, ?, ?, ?, ?)',
      [
        chainId,
        strategy.label,
        status,
        summary,
        startedAt.millisecondsSinceEpoch,
        finishedAt.millisecondsSinceEpoch,
      ],
    );
    final runId = _db.lastInsertRowId;
    final stmt = _db.prepare(
        'INSERT INTO sync_steps (run_id, position, branch, parent, status, detail) VALUES (?, ?, ?, ?, ?, ?)');
    try {
      for (var i = 0; i < steps.length; i++) {
        final s = steps[i];
        stmt.execute([runId, i, s.branch, s.parent, s.status.name, s.detail]);
      }
    } finally {
      stmt.close();
    }
    return runId;
  }

  /// Most recent sync runs for a chain, newest first.
  List<SyncRun> listSyncRuns(int chainId, {int limit = 50}) {
    final rows = _db.select(
        'SELECT * FROM sync_runs WHERE chain_id = ? ORDER BY started_at DESC LIMIT ?',
        [chainId, limit]);
    return rows
        .map((r) => SyncRun(
              id: r['id'] as int,
              chainId: r['chain_id'] as int,
              strategy: SyncStrategy.fromLabel(r['strategy'] as String),
              status: r['status'] as String,
              summary: r['summary'] as String,
              startedAt: _date(r['started_at'])!,
              finishedAt: _date(r['finished_at']),
            ))
        .toList();
  }

  void close() => _db.close();
}
