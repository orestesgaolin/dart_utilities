import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

typedef _LstatNative = Int32 Function(Pointer<Utf8> path, Pointer<Uint8> buf);
typedef _LstatDart = int Function(Pointer<Utf8> path, Pointer<Uint8> buf);
typedef _FstatatNative =
    Int32 Function(
      Int32 dirfd,
      Pointer<Utf8> path,
      Pointer<Uint8> buf,
      Int32 flags,
    );
typedef _FstatatDart =
    int Function(int dirfd, Pointer<Utf8> path, Pointer<Uint8> buf, int flags);

/// File identity based on device and inode numbers.
///
/// Used to detect hardlinks: files sharing the same (dev, ino) pair
/// refer to the same physical data on disk.
typedef FileId = (int dev, int ino);

enum NativeFileType { file, directory, link, other }

/// Result of a native lstat() call.
class NativeStat {
  final FileId id;
  final int nlink;
  final NativeFileType type;

  /// Physical disk allocation in bytes (st_blocks * 512).
  /// This is what `du` uses and matches Finder's "size on disk".
  final int physicalSize;

  NativeStat({
    required this.id,
    required this.nlink,
    required this.type,
    required this.physicalSize,
  });
}

/// Reuses the native stat buffer for a sequence of lstat() calls.
class FileIdentityReader {
  late final Pointer<Uint8>? _statBuffer;
  Pointer<Uint8>? _pathBuffer;
  int _pathBufferSize = 0;
  bool _closed = false;

  FileIdentityReader() {
    FileIdentity._init();
    _statBuffer = FileIdentity._available
        ? malloc<Uint8>(FileIdentity._statBufferSize)
        : null;
  }

  bool get isAvailable => _statBuffer != null;

  bool get supportsStatAt => FileIdentity._fstatat != null;

  NativeStat? stat(String path) {
    final statBuffer = _statBuffer;
    if (_closed || statBuffer == null) return null;
    final pathPointer = _writePath(path);
    return FileIdentity._statWithNativePath(pathPointer.cast(), statBuffer);
  }

  NativeStat? statAt(int directoryFd, String name) {
    final statBuffer = _statBuffer;
    if (_closed || statBuffer == null || !supportsStatAt) return null;
    final pathPointer = _writePath(name);
    return FileIdentity._statAtWithNativePath(
      directoryFd,
      pathPointer.cast(),
      statBuffer,
    );
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    final statBuffer = _statBuffer;
    if (statBuffer != null) {
      malloc.free(statBuffer);
    }
    final pathBuffer = _pathBuffer;
    if (pathBuffer != null) {
      malloc.free(pathBuffer);
    }
  }

  Pointer<Uint8> _writePath(String path) {
    final bytes = utf8.encode(path);
    final requiredSize = bytes.length + 1;
    if (_pathBuffer == null || _pathBufferSize < requiredSize) {
      final oldBuffer = _pathBuffer;
      if (oldBuffer != null) {
        malloc.free(oldBuffer);
      }
      _pathBufferSize = _nextPowerOfTwo(requiredSize);
      _pathBuffer = malloc<Uint8>(_pathBufferSize);
    }

    final pathBuffer = _pathBuffer!;
    final nativeBytes = pathBuffer.asTypedList(requiredSize);
    nativeBytes.setRange(0, bytes.length, bytes);
    nativeBytes[bytes.length] = 0;
    return pathBuffer;
  }

  int _nextPowerOfTwo(int value) {
    var capacity = 256;
    while (capacity < value) {
      capacity *= 2;
    }
    return capacity;
  }
}

/// Provides native file stat via FFI lstat().
///
/// Returns physical disk allocation (st_blocks * 512) and inode info
/// for hardlink detection. Supports macOS and Linux.
class FileIdentity {
  static _LstatDart? _lstat;
  static _FstatatDart? _fstatat;
  static bool _initialized = false;
  static bool _available = false;

  // macOS stat struct offsets (arm64 and x86_64)
  static const _macDevOffset = 0; // Int32
  static const _macModeOffset = 4; // Uint16
  static const _macNlinkOffset = 6; // Uint16
  static const _macInoOffset = 8; // Uint64
  static const _macBlocksOffset = 104; // Int64

  // Linux x86_64 stat struct offsets
  static const _linuxDevOffset = 0; // Uint64
  static const _linuxInoOffset = 8; // Uint64
  static const _linuxNlinkOffset = 16; // Uint64
  static const _linuxModeOffset = 24; // Uint32
  static const _linuxBlocksOffset = 64; // Int64

  static const _statBufferSize = 256;
  static const _modeMask = 0xF000;
  static const _modeFile = 0x8000;
  static const _modeDirectory = 0x4000;
  static const _modeLink = 0xA000;
  static const _atSymlinkNoFollowMacos = 0x20;
  static const _atSymlinkNoFollowLinux = 0x100;

  static void _init() {
    if (_initialized) return;
    _initialized = true;

    if (!Platform.isMacOS && !Platform.isLinux) return;

    try {
      final dylib = DynamicLibrary.process();
      _lstat = dylib.lookupFunction<_LstatNative, _LstatDart>('lstat');
      _fstatat = dylib.lookupFunction<_FstatatNative, _FstatatDart>('fstatat');
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
    final buf = malloc<Uint8>(_statBufferSize);
    try {
      return _statWithNativePath(pathPtr, buf);
    } finally {
      malloc.free(buf);
      malloc.free(pathPtr);
    }
  }

  static NativeStat? _statWithNativePath(
    Pointer<Utf8> pathPtr,
    Pointer<Uint8> buf,
  ) {
    final result = _lstat!(pathPtr.cast(), buf);
    if (result != 0) return null;

    return _statFromBuffer(buf);
  }

  static NativeStat? _statAtWithNativePath(
    int directoryFd,
    Pointer<Utf8> pathPtr,
    Pointer<Uint8> buf,
  ) {
    final result = _fstatat!(
      directoryFd,
      pathPtr,
      buf,
      Platform.isMacOS ? _atSymlinkNoFollowMacos : _atSymlinkNoFollowLinux,
    );
    if (result != 0) return null;

    return _statFromBuffer(buf);
  }

  static NativeStat _statFromBuffer(Pointer<Uint8> buf) {
    int dev, ino, mode, nlink, blocks;
    if (Platform.isMacOS) {
      dev = Pointer<Int32>.fromAddress(buf.address + _macDevOffset).value;
      mode = Pointer<Uint16>.fromAddress(buf.address + _macModeOffset).value;
      nlink = Pointer<Uint16>.fromAddress(buf.address + _macNlinkOffset).value;
      ino = Pointer<Uint64>.fromAddress(buf.address + _macInoOffset).value;
      blocks = Pointer<Int64>.fromAddress(buf.address + _macBlocksOffset).value;
    } else {
      // Linux
      dev = Pointer<Uint64>.fromAddress(buf.address + _linuxDevOffset).value;
      ino = Pointer<Uint64>.fromAddress(buf.address + _linuxInoOffset).value;
      nlink = Pointer<Uint64>.fromAddress(
        buf.address + _linuxNlinkOffset,
      ).value;
      mode = Pointer<Uint32>.fromAddress(buf.address + _linuxModeOffset).value;
      blocks = Pointer<Int64>.fromAddress(
        buf.address + _linuxBlocksOffset,
      ).value;
    }

    return NativeStat(
      id: (dev, ino),
      nlink: nlink,
      type: _typeFromMode(mode),
      physicalSize: blocks * 512,
    );
  }

  static NativeFileType _typeFromMode(int mode) {
    return switch (mode & _modeMask) {
      _modeFile => NativeFileType.file,
      _modeDirectory => NativeFileType.directory,
      _modeLink => NativeFileType.link,
      _ => NativeFileType.other,
    };
  }
}
