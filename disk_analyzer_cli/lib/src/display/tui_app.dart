import 'dart:async';
import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

import '../config.dart';
import '../display/size_formatter.dart';
import '../scanner/scan_worker.dart';
import '../storage/database.dart';
import '../storage/models.dart';

/// An entry in the TUI list — either from the DB or discovered on disk.
class _DisplayEntry {
  final String path;
  final String name;
  final bool isDirectory;
  final int size;
  final bool isScanned;

  _DisplayEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    required this.size,
    required this.isScanned,
  });

  /// Create from a cached DB entry (always scanned).
  factory _DisplayEntry.fromDb(FileEntry e) => _DisplayEntry(
        path: e.path,
        name: e.name,
        isDirectory: e.isDirectory,
        size: e.size,
        isScanned: true,
      );
}

/// Interactive TUI app for exploring disk usage.
class DiskUsageApp extends StatefulComponent {
  const DiskUsageApp({
    required this.db,
    required this.scanId,
    required this.rootPath,
    required this.config,
    super.key,
  });

  final DiskDatabase db;
  final int scanId;
  final String rootPath;
  final AnalyzerConfig config;

  @override
  State<DiskUsageApp> createState() => _DiskUsageAppState();
}

class _DiskUsageAppState extends State<DiskUsageApp> {
  late List<String> _pathStack;
  List<_DisplayEntry> _entries = [];
  int _selectedIndex = 0;
  FileEntry? _currentEntry;
  late int _rootTotalSize;
  final _scrollController = ScrollController();

  /// Remembers which child was selected when navigating into a folder,
  /// keyed by parent path -> child path.
  final _selectionHistory = <String, String>{};

  /// Status message shown in the header.
  String? _statusMessage;

  /// Queue of folder paths waiting to be scanned.
  final _scanQueue = <String>[];

  /// Path currently being scanned (null if idle).
  String? _activeScanPath;

  /// Timer to throttle UI updates from the worker.
  Timer? _progressThrottle;

  /// Whether the settings panel is visible.
  bool _showSettings = false;

  /// Selected index within the settings panel.
  int _settingsIndex = 0;

  /// Last progress data from the worker (applied on throttle tick).
  ScanWorkerProgress? _pendingProgress;

  @override
  void initState() {
    super.initState();
    _pathStack = [component.rootPath];

    final scan = component.db.getLatestScan(component.rootPath) ??
        component.db.findScanContaining(component.rootPath);
    _rootTotalSize = scan?.totalSize ?? 0;

    _loadEntries(component.rootPath);
  }

  /// Loads entries for [path]. If [selectPath] is given, the entry with that
  /// path will be selected (useful to keep focus after a rescan moves items).
  void _loadEntries(String path, {String? selectPath}) {
    _currentEntry = component.db.getEntry(component.scanId, path);

    final dbEntries = component.db.queryEntries(
      scanId: component.scanId,
      parentPath: path,
      sortBy: 'size',
      descending: true,
    );

    // Build display entries from DB and track cached paths
    final cachedPaths = <String>{};
    final displayEntries = <_DisplayEntry>[];
    for (final e in dbEntries) {
      cachedPaths.add(e.path);
      displayEntries.add(_DisplayEntry.fromDb(e));
    }

    _entries = displayEntries;

    // Restore selection to the requested path, or reset to top
    if (selectPath != null) {
      final idx = _entries.indexWhere((e) => e.path == selectPath);
      _selectedIndex = idx >= 0 ? idx : 0;
    } else {
      _selectedIndex = 0;
    }
    if (_selectedIndex == 0) {
      _scrollController.jumpTo(0);
    } else {
      _scrollToSelected();
    }

    // Async: discover entries on disk, auto-add files, prune stale entries
    _syncWithDisk(path, cachedPaths);
  }

  /// Lists the actual directory on disk, adds unscanned files to the DB,
  /// removes stale DB entries for files/dirs that no longer exist, and
  /// appends unscanned directories to the display list.
  Future<void> _syncWithDisk(
      String parentPath, Set<String> cachedPaths) async {
    final dir = Directory(parentPath);
    if (!dir.existsSync()) return;

    try {
      final diskPaths = <String>{};
      final unscannedDirs = <_DisplayEntry>[];

      // Get parent depth to calculate child depth
      final parentDepth =
          component.db.getEntryDepth(component.scanId, parentPath);
      final childDepth = (parentDepth ?? 0) + 1;

      await for (final entity in dir.list(followLinks: false)) {
        diskPaths.add(entity.path);

        if (!cachedPaths.contains(entity.path)) {
          final stat = entity.statSync();
          final isDir = stat.type == FileSystemEntityType.directory;

          if (!isDir) {
            // Auto-add unscanned files to the DB
            component.db.insertEntry(
              component.scanId,
              FileEntry(
                path: entity.path,
                isDirectory: false,
                size: stat.size,
                depth: childDepth,
                parentPath: parentPath,
              ),
            );
          } else {
            // Collect unscanned dirs for display (not auto-added)
            unscannedDirs.add(_DisplayEntry(
              path: entity.path,
              name: p.basename(entity.path),
              isDirectory: true,
              size: 0,
              isScanned: false,
            ));
          }
        }
      }

      // Prune stale DB entries (files/dirs that no longer exist on disk)
      for (final cached in cachedPaths) {
        if (!diskPaths.contains(cached)) {
          component.db.deleteEntry(component.scanId, cached);
        }
      }

      if (!mounted) return;

      // Check if any files were added or removed
      final filesChanged = cachedPaths
              .difference(diskPaths)
              .isNotEmpty ||
          diskPaths.difference(cachedPaths).any((path) {
            try {
              return !FileSystemEntity.isDirectorySync(path);
            } catch (_) {
              return false;
            }
          });

      if (filesChanged) {
        // Re-read from DB to pick up auto-added files and pruned entries
        final refreshed = component.db.queryEntries(
          scanId: component.scanId,
          parentPath: parentPath,
          sortBy: 'size',
          descending: true,
        );
        final refreshedDisplay =
            refreshed.map(_DisplayEntry.fromDb).toList();

        // Preserve selection by path
        final currentSelectedPath = _entries.isNotEmpty
            ? _entries[_selectedIndex].path
            : null;

        setState(() {
          _entries = [...refreshedDisplay, ...unscannedDirs];
          if (currentSelectedPath != null) {
            final idx =
                _entries.indexWhere((e) => e.path == currentSelectedPath);
            if (idx >= 0) _selectedIndex = idx;
          }
        });
      } else if (unscannedDirs.isNotEmpty) {
        unscannedDirs.sort((a, b) => a.name.compareTo(b.name));
        setState(() {
          _entries = [..._entries, ...unscannedDirs];
        });
      }
    } catch (_) {
      // Permission errors — silently ignore
    }
  }

  @override
  void dispose() {
    _progressThrottle?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToSelected() {
    _scrollController.ensureIndexVisible(index: _selectedIndex);
  }

  String get _currentPath => _pathStack.last;

  void _navigateInto(_DisplayEntry entry) {
    if (!entry.isDirectory) return;
    // Remember current selection for back-navigation
    _selectionHistory[_currentPath] = entry.path;
    setState(() {
      _pathStack.add(entry.path);
      _loadEntries(entry.path);
    });
  }

  void _navigateBack() {
    if (_pathStack.length <= 1) return;
    final leavingPath = _currentPath;
    setState(() {
      _pathStack.removeLast();
      // Restore selection to the folder we just came from
      final previousSelection = _selectionHistory[_currentPath] ?? leavingPath;
      _loadEntries(_currentPath, selectPath: previousSelection);
    });
  }

  /// Enqueue the selected folder for scanning.
  void _scanSelected() {
    if (_entries.isEmpty) return;
    final entry = _entries[_selectedIndex];
    if (!entry.isDirectory) return;
    _enqueueScan(entry.path);
  }

  /// Enqueue all unscanned directories in the current view.
  void _scanAllUnscanned() {
    for (final entry in _entries) {
      if (entry.isDirectory && !entry.isScanned) {
        _enqueueScan(entry.path);
      }
    }
  }

  /// Add a path to the scan queue (deduplicating).
  void _enqueueScan(String path) {
    if (path == _activeScanPath || _scanQueue.contains(path)) return;
    _scanQueue.add(path);
    setState(() {
      _statusMessage = _buildQueueStatus();
    });
    if (_activeScanPath == null) {
      _processNextScan();
    }
  }

  /// Open the selected entry in Finder.
  void _openInFinder() {
    if (_entries.isEmpty) return;
    final entry = _entries[_selectedIndex];
    final target = entry.isDirectory ? entry.path : p.dirname(entry.path);
    Process.start('open', [target], mode: ProcessStartMode.detached);
  }

  String _buildQueueStatus() {
    final parts = <String>[];
    if (_activeScanPath != null) {
      parts.add('\u{1f50d} ${p.basename(_activeScanPath!)}');
    }
    if (_scanQueue.isNotEmpty) {
      parts.add('\u{23f3} ${_scanQueue.length} queued');
    }
    return parts.join('  \u{00b7}  ');
  }

  /// Start the next scan from the queue in a background isolate.
  void _processNextScan() {
    if (_scanQueue.isEmpty) {
      _activeScanPath = null;
      _progressThrottle?.cancel();
      if (mounted) setState(() => _statusMessage = null);
      return;
    }

    final targetPath = _scanQueue.removeAt(0);
    _activeScanPath = targetPath;
    if (mounted) setState(() => _statusMessage = _buildQueueStatus());

    // Calculate depth offset relative to the scan root
    final scan = component.db.getLatestScan(component.rootPath) ??
        component.db.findScanContaining(component.rootPath);
    final rootPath = scan?.rootPath ?? component.rootPath;
    final depthOffset =
        targetPath.split('/').length - rootPath.split('/').length;

    // Start throttle timer for progress updates (250ms)
    _progressThrottle?.cancel();
    _progressThrottle = Timer.periodic(Duration(milliseconds: 250), (_) {
      final pending = _pendingProgress;
      if (pending != null && mounted) {
        _pendingProgress = null;
        setState(() {
          _statusMessage =
              '\u{1f50d} ${p.basename(targetPath)}: '
              '${pending.filesScanned} files, '
              '${SizeFormatter.format(pending.bytesScanned)}'
              '${_scanQueue.isNotEmpty ? '  \u{00b7}  \u{23f3} ${_scanQueue.length} queued' : ''}';
        });
      }
    });

    // Launch the scan in a background isolate
    launchScanWorker(
      dbPath: component.db.dbPath,
      targetPath: targetPath,
      scanId: component.scanId,
      rootPath: rootPath,
      depthOffset: depthOffset,
      collapsedDirs: component.config.collapsedDirs,
    ).then((handle) {
      handle.listen(
        onProgress: (progress) {
          _pendingProgress = progress;
        },
        onDone: (result) {
          _progressThrottle?.cancel();
          _pendingProgress = null;

          final updatedScan = component.db.getLatestScan(rootPath) ??
              component.db.findScanContaining(rootPath);
          _rootTotalSize = updatedScan?.totalSize ?? _rootTotalSize;

          if (mounted) {
            setState(() {
              _statusMessage =
                  '\u{2705} ${p.basename(targetPath)}: '
                  '${SizeFormatter.format(result.totalSize)} '
                  '(${result.fileCount} files)';

              // Refresh the view if we're looking at the scanned folder's parent
              final scanParent = p.dirname(targetPath);
              if (scanParent == _currentPath) {
                final selectedPath = _entries.isNotEmpty
                    ? _entries[_selectedIndex].path
                    : null;
                _loadEntries(_currentPath, selectPath: selectedPath);
              }
            });

            Future.delayed(Duration(seconds: 2), () {
              if (mounted) _processNextScan();
            });
          }
        },
        onError: (error) {
          _progressThrottle?.cancel();
          _pendingProgress = null;

          if (mounted) {
            setState(() {
              _statusMessage =
                  '\u{26a0}\u{fe0f}  ${p.basename(targetPath)}: $error';
            });

            Future.delayed(Duration(seconds: 2), () {
              if (mounted) _processNextScan();
            });
          }
        },
      );
    });
  }

  @override
  Component build(BuildContext context) {
    final currentSize = _currentEntry?.size ?? _rootTotalSize;

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        // Settings panel key handling
        if (_showSettings) {
          return _handleSettingsKey(event);
        }

        if (event.logicalKey == LogicalKey.keyQ ||
            event.logicalKey == LogicalKey.escape && _pathStack.length <= 1) {
          shutdownApp();
          return true;
        }
        if (event.logicalKey == LogicalKey.arrowUp) {
          setState(() {
            if (_selectedIndex > 0) _selectedIndex--;
          });
          _scrollToSelected();
          return true;
        }
        if (event.logicalKey == LogicalKey.arrowDown) {
          setState(() {
            if (_selectedIndex < _entries.length - 1) _selectedIndex++;
          });
          _scrollToSelected();
          return true;
        }
        if (event.logicalKey == LogicalKey.enter) {
          if (_entries.isNotEmpty && _entries[_selectedIndex].isDirectory) {
            _navigateInto(_entries[_selectedIndex]);
          }
          return true;
        }
        // s = scan selected, Shift+S = scan all unscanned
        if (event.logicalKey == LogicalKey.keyS) {
          if (event.isShiftPressed) {
            _scanAllUnscanned();
          } else {
            _scanSelected();
          }
          return true;
        }
        if (event.logicalKey == LogicalKey.keyR) {
          setState(() => _loadEntries(_currentPath));
          return true;
        }
        // o = open in Finder
        if (event.logicalKey == LogicalKey.keyO && !event.isShiftPressed && !event.isMetaPressed && !event.isControlPressed) {
          _openInFinder();
          return true;
        }
        // , = open settings
        if (event.logicalKey == LogicalKey.comma) {
          setState(() {
            _showSettings = true;
            _settingsIndex = 0;
          });
          return true;
        }
        if (event.logicalKey == LogicalKey.pageUp) {
          setState(() {
            _selectedIndex =
                (_selectedIndex - 20).clamp(0, _entries.length - 1);
          });
          _scrollToSelected();
          return true;
        }
        if (event.logicalKey == LogicalKey.pageDown) {
          setState(() {
            _selectedIndex =
                (_selectedIndex + 20).clamp(0, _entries.length - 1);
          });
          _scrollToSelected();
          return true;
        }
        if (event.logicalKey == LogicalKey.home) {
          setState(() => _selectedIndex = 0);
          _scrollToSelected();
          return true;
        }
        if (event.logicalKey == LogicalKey.end) {
          setState(() => _selectedIndex = _entries.length - 1);
          _scrollToSelected();
          return true;
        }
        if (event.logicalKey == LogicalKey.backspace ||
            event.logicalKey == LogicalKey.escape) {
          _navigateBack();
          return true;
        }
        return false;
      },
      child: Container(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(currentSize),
            Divider(style: DividerStyle.single, color: Colors.gray),
            Expanded(
              child: _showSettings
                  ? _buildSettingsPanel()
                  : _entries.isEmpty
                      ? Center(
                          child: Text(
                            'No entries found',
                            style: TextStyle(color: Colors.gray),
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          keyboardScrollable: false,
                          itemExtent: 1,
                          itemCount: _entries.length,
                          itemBuilder: (context, index) {
                            return _buildEntryRow(
                              _entries[index],
                              index,
                              currentSize,
                            );
                          },
                        ),
            ),
            Divider(style: DividerStyle.single, color: Colors.gray),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Component _buildHeader(int currentSize) {
    final breadcrumb = _pathStack.length > 1
        ? _pathStack
            .map((seg) =>
                seg.split('/').last.isEmpty ? '/' : seg.split('/').last)
            .join(' \u{203a} ')
        : _currentPath;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: 1),
          Text(
            '\u{1f4ca} Disk Usage Explorer',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.cyan),
          ),
          Text(
            breadcrumb,
            style: TextStyle(color: Colors.gray),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
          Text(
            'Total: ${SizeFormatter.format(currentSize)}  '
            '(${_entries.length} items)',
            style: TextStyle(color: Colors.white),
          ),
          if (_statusMessage != null)
            Text(
              _statusMessage!,
              style: TextStyle(color: Colors.yellow),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
        ],
      ),
    );
  }

  Component _buildEntryRow(_DisplayEntry entry, int index, int parentSize) {
    final isSelected = index == _selectedIndex;
    final isBeingScanned = entry.path == _activeScanPath;
    final isQueued = _scanQueue.contains(entry.path);

    final String icon;
    if (isBeingScanned) {
      icon = '\u{1f504}';
    } else if (isQueued) {
      icon = '\u{23f3}';
    } else if (entry.isDirectory) {
      icon = entry.isScanned ? '\u{1f4c1}' : '\u{1f4c2}';
    } else {
      icon = '\u{1f4c4}';
    }
    final size = entry.isScanned || !entry.isDirectory
        ? SizeFormatter.format(entry.size)
        : '?';
    final pct = parentSize > 0 && entry.isScanned
        ? (entry.size / parentSize * 100)
        : 0.0;
    final pctStr = entry.isScanned ? '${pct.toStringAsFixed(1)}%' : '  [?]';

    const barWidth = 20;
    final filled = parentSize > 0 && entry.isScanned
        ? (entry.size / parentSize * barWidth).round().clamp(0, barWidth)
        : 0;
    final bar = entry.isScanned
        ? '\u{2588}' * filled + '\u{2591}' * (barWidth - filled)
        : '\u{00b7}' * barWidth;

    final Color barColor;
    if (!entry.isScanned) {
      barColor = Colors.brightBlack;
    } else if (pct > 50) {
      barColor = Colors.red;
    } else if (pct > 25) {
      barColor = Colors.yellow;
    } else if (pct > 10) {
      barColor = Colors.green;
    } else {
      barColor = Colors.gray;
    }

    final nameColor = !entry.isScanned
        ? (isSelected ? Colors.yellow : Colors.brightBlack)
        : (isSelected ? Colors.cyan : Colors.white);

    final nameStyle = TextStyle(
      fontWeight: isSelected ? FontWeight.bold : null,
      color: nameColor,
    );

    final bgColor = isSelected ? Color.fromRGB(30, 50, 70) : null;

    final dirIndicator =
        entry.isDirectory ? (entry.isScanned ? ' \u{25b8}' : ' \u{26a1}') : '';

    return Container(
      decoration: bgColor != null ? BoxDecoration(color: bgColor) : null,
      padding: EdgeInsets.symmetric(horizontal: 1),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.maxWidth - 2;
          final nameWidth = (availableWidth - 42).clamp(10, 200).toDouble();

          return Row(
            children: [
              Text('$icon '),
              SizedBox(
                width: nameWidth,
                child: Text(
                  '${entry.name}$dirIndicator',
                  style: nameStyle,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              SizedBox(
                width: 10,
                child: Text(
                  size,
                  style: TextStyle(
                    color: entry.isScanned ? Colors.white : Colors.brightBlack,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
              Text(' '),
              Text(bar, style: TextStyle(color: barColor)),
              Text(' '),
              SizedBox(
                width: 6,
                child: Text(
                  pctStr,
                  style: TextStyle(
                    color: entry.isScanned ? Colors.gray : Colors.brightBlack,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  bool _handleSettingsKey(KeyboardEvent event) {
    final items = _settingsItems;

    if (event.logicalKey == LogicalKey.escape ||
        event.logicalKey == LogicalKey.comma ||
        event.logicalKey == LogicalKey.backspace) {
      setState(() => _showSettings = false);
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowUp) {
      setState(() {
        if (_settingsIndex > 0) _settingsIndex--;
      });
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowDown) {
      setState(() {
        if (_settingsIndex < items.length - 1) _settingsIndex++;
      });
      return true;
    }
    if (event.logicalKey == LogicalKey.enter ||
        event.logicalKey == LogicalKey.space) {
      _toggleSettingsItem(_settingsIndex);
      return true;
    }
    // 'a' to add a new collapsed dir
    if (event.logicalKey == LogicalKey.keyA) {
      _addCollapsedDir();
      return true;
    }
    // 'd' or delete to remove selected
    if (event.logicalKey == LogicalKey.keyD ||
        event.logicalKey == LogicalKey.delete) {
      _removeSettingsItem(_settingsIndex);
      return true;
    }
    if (event.logicalKey == LogicalKey.keyQ) {
      setState(() => _showSettings = false);
      return true;
    }
    return true; // Consume all keys in settings mode
  }

  /// Settings items: list of collapsed dir names with toggle state.
  List<({String name, bool enabled})> get _settingsItems {
    return component.config.collapsedDirs
        .map((d) => (name: d, enabled: true))
        .toList();
  }

  void _toggleSettingsItem(int index) {
    final items = component.config.collapsedDirs;
    if (index < 0 || index >= items.length) return;
    setState(() {
      component.config.collapsedDirs.removeAt(index);
      component.config.save();
    });
  }

  void _removeSettingsItem(int index) {
    final items = component.config.collapsedDirs;
    if (index < 0 || index >= items.length) return;
    setState(() {
      items.removeAt(index);
      if (_settingsIndex >= items.length && items.isNotEmpty) {
        _settingsIndex = items.length - 1;
      }
      component.config.save();
    });
  }

  void _addCollapsedDir() {
    // Add a placeholder — in a real app this would be an input field.
    // For now, cycle through common defaults not already in the list.
    const suggestions = [
      'node_modules',
      '.git',
      'build',
      '.dart_tool',
      'target',
      '.gradle',
      '__pycache__',
      'venv',
      '.venv',
      'dist',
      'vendor',
      'Pods',
      '.cache',
    ];
    final current = component.config.collapsedDirs.toSet();
    final next = suggestions.where((s) => !current.contains(s)).firstOrNull;
    if (next != null) {
      setState(() {
        component.config.collapsedDirs.add(next);
        _settingsIndex = component.config.collapsedDirs.length - 1;
        component.config.save();
      });
    }
  }

  Component _buildSettingsPanel() {
    final items = component.config.collapsedDirs;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '\u{2699}\u{fe0f}  Settings',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.cyan),
          ),
          SizedBox(height: 1),
          Text(
            'Collapsed Directories (not recursed during scan, only total size recorded):',
            style: TextStyle(color: Colors.gray),
          ),
          SizedBox(height: 1),
          ...List.generate(items.length, (index) {
            final isSelected = index == _settingsIndex;
            final bgColor = isSelected ? Color.fromRGB(30, 50, 70) : null;
            return Container(
              decoration:
                  bgColor != null ? BoxDecoration(color: bgColor) : null,
              child: Text(
                '  ${isSelected ? '\u{25b6}' : ' '} ${items[index]}',
                style: TextStyle(
                  color: isSelected ? Colors.cyan : Colors.white,
                  fontWeight: isSelected ? FontWeight.bold : null,
                ),
              ),
            );
          }),
          if (items.isEmpty)
            Text(
              '  (none)',
              style: TextStyle(color: Colors.brightBlack),
            ),
          SizedBox(height: 1),
          Text(
            '\u{2191}\u{2193} Select  a Add  d Remove  Esc/,/q Close',
            style: TextStyle(color: Colors.gray),
          ),
        ],
      ),
    );
  }

  Component _buildFooter() {
    final scannedCount = _entries.where((e) => e.isScanned).length;
    final totalCount = _entries.length;
    final scannedSize =
        _entries.where((e) => e.isScanned).fold<int>(0, (s, e) => s + e.size);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              '\u{2191}\u{2193} Nav  \u{23ce} Open  \u{232b} Back  s Scan  S All  o Finder  , Settings  q Quit',
              style: TextStyle(color: Colors.gray),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          Text(
            ' $scannedCount/$totalCount scanned  ${SizeFormatter.format(scannedSize)}',
            style: TextStyle(color: Colors.gray),
          ),
        ],
      ),
    );
  }
}
