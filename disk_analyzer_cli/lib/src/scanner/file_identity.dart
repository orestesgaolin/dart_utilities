import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

typedef _LstatNative = Int32 Function(Pointer<Utf8> path, Pointer<Uint8> buf);
typedef _LstatDart = int Function(Pointer<Utf8> path, Pointer<Uint8> buf);

/// File identity based on device and inode numbers.
///
/// Used to detect hardlinks: files sharing the same (dev, ino) pair
/// refer to the same physical data on disk.
typedef FileId = (int dev, int ino);

/// Result of a native lstat() call.
class NativeStat {
  final FileId id;
  final int nlink;

  /// Physical disk allocation in bytes (st_blocks * 512).
  /// This is what `du` uses and matches Finder's "size on disk".
  final int physicalSize;

  NativeStat({required this.id, required this.nlink, required this.physicalSize});
}

/// Provides native file stat via FFI lstat().
///
/// Returns physical disk allocation (st_blocks * 512) and inode info
/// for hardlink detection. Supports macOS and Linux.
class FileIdentity {
  static _LstatDart? _lstat;
  static bool _initialized = false;
  static bool _available = false;

  // macOS stat struct offsets (arm64 and x86_64)
  static const _macDevOffset = 0; // Int32
  static const _macNlinkOffset = 6; // Uint16
  static const _macInoOffset = 8; // Uint64
  static const _macBlocksOffset = 104; // Int64

  // Linux x86_64 stat struct offsets
  static const _linuxDevOffset = 0; // Uint64
  static const _linuxInoOffset = 8; // Uint64
  static const _linuxNlinkOffset = 16; // Uint64
  static const _linuxBlocksOffset = 64; // Int64

  static void _init() {
    if (_initialized) return;
    _initialized = true;

    if (!Platform.isMacOS && !Platform.isLinux) return;

    try {
      final dylib = DynamicLibrary.process();
      _lstat = dylib.lookupFunction<_LstatNative, _LstatDart>('lstat');
      _available = true;
    } catch (_) {
      _available = false;
    }
  }

  /// Whether native file stat is available on this platform.
  static bool get isAvailable {
    _init();
    return _available;
  }

  /// Get file identity, hardlink count, and physical size for a path.
  ///
  /// Returns null if native stat is unavailable or the call fails.
  static NativeStat? stat(String path) {
    _init();
    if (!_available) return null;

    final pathPtr = path.toNativeUtf8(allocator: malloc);
    final buf = malloc<Uint8>(256);
    try {
      final result = _lstat!(pathPtr.cast(), buf);
      if (result != 0) return null;

      int dev, ino, nlink, blocks;
      if (Platform.isMacOS) {
        dev = Pointer<Int32>.fromAddress(buf.address + _macDevOffset).value;
        nlink = Pointer<Uint16>.fromAddress(buf.address + _macNlinkOffset).value;
        ino = Pointer<Uint64>.fromAddress(buf.address + _macInoOffset).value;
        blocks = Pointer<Int64>.fromAddress(buf.address + _macBlocksOffset).value;
      } else {
        // Linux
        dev = Pointer<Uint64>.fromAddress(buf.address + _linuxDevOffset).value;
        ino = Pointer<Uint64>.fromAddress(buf.address + _linuxInoOffset).value;
        nlink = Pointer<Uint64>.fromAddress(buf.address + _linuxNlinkOffset).value;
        blocks = Pointer<Int64>.fromAddress(buf.address + _linuxBlocksOffset).value;
      }

      return NativeStat(
        id: (dev, ino),
        nlink: nlink,
        physicalSize: blocks * 512,
      );
    } finally {
      malloc.free(buf);
      malloc.free(pathPtr);
    }
  }
}
