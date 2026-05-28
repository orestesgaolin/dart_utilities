import 'dart:ffi';
import 'dart:io' show FileSystemException, Platform;

import 'package:ffi/ffi.dart';

typedef _OpendirNative = Pointer<Void> Function(Pointer<Utf8> path);
typedef _OpendirDart = Pointer<Void> Function(Pointer<Utf8> path);
typedef _ReaddirNative = Pointer<Void> Function(Pointer<Void> dir);
typedef _ReaddirDart = Pointer<Void> Function(Pointer<Void> dir);
typedef _ClosedirNative = Int32 Function(Pointer<Void> dir);
typedef _ClosedirDart = int Function(Pointer<Void> dir);
typedef _DirfdNative = Int32 Function(Pointer<Void> dir);
typedef _DirfdDart = int Function(Pointer<Void> dir);

class NativeDirectoryReader {
  static _OpendirDart? _opendir;
  static _ReaddirDart? _readdir;
  static _ClosedirDart? _closedir;
  static _DirfdDart? _dirfd;
  static bool _initialized = false;
  static bool _available = false;

  static bool get isAvailable {
    _init();
    return _available;
  }

  static NativeDirectory open(String path) {
    _init();
    if (!_available) {
      throw FileSystemException(
        'Native directory reading is unavailable',
        path,
      );
    }

    final pathPtr = path.toNativeUtf8(allocator: malloc);
    try {
      final dir = _opendir!(pathPtr);
      if (dir == nullptr) {
        throw FileSystemException('Cannot open directory', path);
      }
      final fd = _dirfd!(dir);
      if (fd < 0) {
        _closedir!(dir);
        throw FileSystemException('Cannot get directory descriptor', path);
      }
      return NativeDirectory._(dir, fd);
    } finally {
      malloc.free(pathPtr);
    }
  }

  static void _init() {
    if (_initialized) return;
    _initialized = true;

    if (!Platform.isMacOS && !Platform.isLinux) return;

    try {
      final dylib = DynamicLibrary.process();
      _opendir = dylib.lookupFunction<_OpendirNative, _OpendirDart>('opendir');
      _readdir = dylib.lookupFunction<_ReaddirNative, _ReaddirDart>('readdir');
      _closedir = dylib.lookupFunction<_ClosedirNative, _ClosedirDart>(
        'closedir',
      );
      _dirfd = dylib.lookupFunction<_DirfdNative, _DirfdDart>('dirfd');
      _available = true;
    } catch (_) {
      _available = false;
    }
  }
}

class NativeDirectory {
  final Pointer<Void> _dir;
  final int fd;

  bool _closed = false;

  NativeDirectory._(this._dir, this.fd);

  String? nextName() {
    if (_closed) return null;

    while (true) {
      final entry = NativeDirectoryReader._readdir!(_dir);
      if (entry == nullptr) return null;
      final name = _readName(entry);
      if (name == '.' || name == '..') continue;
      return name;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    NativeDirectoryReader._closedir!(_dir);
  }

  String _readName(Pointer<Void> entry) {
    final address = entry.address;
    if (Platform.isMacOS) {
      const nameLengthOffset = 18;
      const nameOffset = 21;
      final nameLength = Pointer<Uint16>.fromAddress(
        address + nameLengthOffset,
      ).value;
      return Pointer<Utf8>.fromAddress(
        address + nameOffset,
      ).toDartString(length: nameLength);
    }

    const nameOffset = 19;
    return Pointer<Utf8>.fromAddress(address + nameOffset).toDartString();
  }
}
