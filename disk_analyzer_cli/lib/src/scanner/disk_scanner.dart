import 'dart:io';

import '../storage/models.dart';
import 'file_identity.dart';

/// Progress data reported during a scan.
class ScanProgress {
  final String currentPath;
  final int filesScanned;
  final int dirsScanned;
  final int bytesScanned;
  final int hardlinksSkipped;

  ScanProgress({
    required this.currentPath,
    required this.filesScanned,
    required this.dirsScanned,
    required this.bytesScanned,
    required this.hardlinksSkipped,
  });
}

/// Callback for reporting scan progress.
typedef ScanProgressCallback = void Function(ScanProgress progress);

/// Callback for emitting scanned entries (streamed to avoid memory buildup).
typedef EntryCallback = void Function(FileEntry entry);

/// Recursively scans a directory tree and computes sizes.
///
/// Instead of accumulating entries in memory, entries are streamed via
/// [onEntry] callback. This keeps memory bounded regardless of tree size.
///
/// Uses native lstat() to detect hardlinks and avoid double-counting
/// files that share the same physical data on disk.
class DiskScanner {
  final bool followLinks;
  final int? maxDepth;
  final Duration? timeout;

  /// Directory names to collapse (don't recurse, just record total size).
  final Set<String> collapsedDirs;

  bool _timedOut = false;

  DiskScanner({
    this.followLinks = false,
    this.maxDepth,
    this.timeout,
    List<String> collapsedDirs = const [],
  }) : collapsedDirs = collapsedDirs.toSet();

  bool get timedOut => _timedOut;

  /// Scan a directory, streaming entries via [onEntry].
  ///
  /// Directory sizes are the sum of all their contents.
  /// Hardlinked files are detected via inode and only counted once.
  /// Returns summary stats; actual entries go to [onEntry].
  Future<ScanResult> scan(
    String rootPath, {
    ScanProgressCallback? onProgress,
    required EntryCallback onEntry,
  }) async {
    final root = Directory(rootPath);
    if (!root.existsSync()) {
      throw ArgumentError('Directory does not exist: $rootPath');
    }

    final canonicalRoot = root.resolveSymbolicLinksSync();
    var totalFiles = 0;
    var totalDirs = 0;
    var totalBytes = 0;
    var hardlinksSkipped = 0;
    final errors = <String>[];
    var lastProgressTime = DateTime.now();
    final startTime = DateTime.now();
    _timedOut = false;

    // Track seen (device, inode) pairs to detect hardlinks
    final seenInodes = <FileId>{};
    final hasNativeIdentity = FileIdentity.isAvailable;

    // Track seen directory inodes to detect firmlinks/bind mounts that
    // loop back to already-scanned directories (e.g. macOS /.nofollow).
    final seenDirInodes = <FileId>{};

    // Get the device ID of the scan root to detect cross-device mounts
    // (e.g. /System/Volumes/Data). Directories on different devices are
    // skipped to avoid double-counting.
    int? rootDeviceId;
    if (hasNativeIdentity) {
      final rootStat = FileIdentity.stat(canonicalRoot);
      if (rootStat != null) {
        rootDeviceId = rootStat.id.$1;
        seenDirInodes.add(rootStat.id);
      }
    }

    // macOS system paths that recursively mirror / — always skip these
    const systemMirrorPaths = {
      '/System/Volumes/Data',
      '/System/Volumes/Data/home',
    };

    void reportProgress(String path) {
      if (onProgress == null) return;
      final now = DateTime.now();
      if (now.difference(lastProgressTime).inMilliseconds < 100) return;
      lastProgressTime = now;
      onProgress(ScanProgress(
        currentPath: path,
        filesScanned: totalFiles,
        dirsScanned: totalDirs,
        bytesScanned: totalBytes,
        hardlinksSkipped: hardlinksSkipped,
      ));
    }

    bool isTimedOut() {
      if (timeout == null) return false;
      if (_timedOut) return true;
      _timedOut = DateTime.now().difference(startTime) >= timeout!;
      return _timedOut;
    }

    /// Get the physical size of a file and check for hardlink duplicates.
    /// Returns 0 if this is a duplicate hardlink.
    /// Uses native stat for physical size (st_blocks * 512) when available,
    /// falls back to Dart's statSync().size (logical size).
    int getFileSize(String path) {
      if (hasNativeIdentity) {
        final nstat = FileIdentity.stat(path);
        if (nstat != null) {
          // Check for hardlink duplicate
          if (nstat.nlink > 1 && !seenInodes.add(nstat.id)) {
            hardlinksSkipped++;
            return 0;
          }
          // Use physical block-based size (matches du/Finder)
          return nstat.physicalSize;
        }
      }
      // Fallback: Dart logical size
      return File(path).statSync().size;
    }

    Future<int> walk(String dirPath, int depth) async {
      if (isTimedOut()) return 0;
      if (maxDepth != null && depth > maxDepth!) return 0;

      var dirSize = 0;
      final dir = Directory(dirPath);

      try {
        await for (final entity in dir.list(followLinks: followLinks)) {
          if (isTimedOut()) break;

          final childDepth = depth + 1;

          try {
            if (entity is File) {
              final size = getFileSize(entity.path);

              onEntry(FileEntry(
                path: entity.path,
                isDirectory: false,
                size: size,
                depth: childDepth,
                parentPath: dirPath,
              ));
              dirSize += size;
              totalFiles++;
              totalBytes += size;
              reportProgress(entity.path);
            } else if (entity is Directory) {
              if (!followLinks && FileSystemEntity.isLinkSync(entity.path)) {
                continue;
              }
              // Skip known macOS paths that mirror the root filesystem
              if (systemMirrorPaths.contains(entity.path)) {
                continue;
              }
              // Skip directories on different devices (cross-device mounts)
              // and directories we've already seen (firmlinks like /.nofollow)
              if (hasNativeIdentity) {
                final dirStat = FileIdentity.stat(entity.path);
                if (dirStat != null) {
                  if (rootDeviceId != null &&
                      dirStat.id.$1 != rootDeviceId) {
                    continue;
                  }
                  if (!seenDirInodes.add(dirStat.id)) {
                    continue;
                  }
                }
              }
              totalDirs++;
              reportProgress(entity.path);

              // Collapsed dirs: record total size without recursing
              final dirBaseName = entity.path.substring(
                  entity.path.lastIndexOf('/') + 1);
              if (collapsedDirs.contains(dirBaseName)) {
                final collapsedSize = await _getDirSize(entity.path);
                onEntry(FileEntry(
                  path: entity.path,
                  isDirectory: true,
                  size: collapsedSize,
                  depth: childDepth,
                  parentPath: dirPath,
                ));
                dirSize += collapsedSize;
                totalBytes += collapsedSize;
              } else {
                final childSize = await walk(entity.path, childDepth);
                onEntry(FileEntry(
                  path: entity.path,
                  isDirectory: true,
                  size: childSize,
                  depth: childDepth,
                  parentPath: dirPath,
                ));
                dirSize += childSize;
              }
            }
          } catch (e) {
            errors.add('Cannot access ${entity.path}: $e');
          }
        }
      } catch (e) {
        errors.add('Cannot list $dirPath: $e');
      }

      return dirSize;
    }

    final totalSize = await walk(canonicalRoot, 0);

    return ScanResult(
      rootPath: canonicalRoot,
      totalSize: totalSize,
      fileCount: totalFiles,
      dirCount: totalDirs,
      errors: errors,
      timedOut: _timedOut,
      hardlinksSkipped: hardlinksSkipped,
    );
  }

  /// Get total physical size of a directory without recursing into it entry by entry.
  /// Uses the native file system to compute the total allocation.
  Future<int> _getDirSize(String dirPath) async {
    var total = 0;
    try {
      await for (final entity
          in Directory(dirPath).list(recursive: true, followLinks: false)) {
        if (entity is File) {
          if (FileIdentity.isAvailable) {
            final stat = FileIdentity.stat(entity.path);
            if (stat != null) {
              total += stat.physicalSize;
              continue;
            }
          }
          total += entity.statSync().size;
        }
      }
    } catch (_) {
      // Permission errors etc — return what we got
    }
    return total;
  }
}

/// Result of a directory scan (summary only — entries streamed via callback).
class ScanResult {
  final String rootPath;
  final int totalSize;
  final int fileCount;
  final int dirCount;
  final List<String> errors;
  final bool timedOut;
  final int hardlinksSkipped;

  ScanResult({
    required this.rootPath,
    required this.totalSize,
    required this.fileCount,
    required this.dirCount,
    required this.errors,
    this.timedOut = false,
    this.hardlinksSkipped = 0,
  });
}
