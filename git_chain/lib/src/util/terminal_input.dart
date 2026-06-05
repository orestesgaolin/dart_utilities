import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _OpenNative = Int32 Function(Pointer<Utf8> path, Int32 flags);
typedef _OpenDart = int Function(Pointer<Utf8> path, int flags);
typedef _TcflushNative = Int32 Function(Int32 fd, Int32 queue);
typedef _TcflushDart = int Function(int fd, int queue);
typedef _CloseNative = Int32 Function(Int32 fd);
typedef _CloseDart = int Function(int fd);

/// Discards any pending bytes in the controlling terminal's input queue.
///
/// We open `/dev/tty` fresh rather than using fd 0: after a nocterm session
/// stdin (fd 0) is closed, so `tcflush(0, …)` fails with EBADF. `/dev/tty`
/// always refers to the controlling terminal, whose input queue still holds the
/// stray reply to nocterm's shutdown Device Attributes query (`ESC[c`).
void drainTerminalInput() {
  if (!(Platform.isMacOS || Platform.isLinux)) return;
  Pointer<Utf8>? path;
  try {
    final lib = DynamicLibrary.process();
    final open = lib.lookupFunction<_OpenNative, _OpenDart>('open');
    final tcflush = lib.lookupFunction<_TcflushNative, _TcflushDart>('tcflush');
    final close = lib.lookupFunction<_CloseNative, _CloseDart>('close');

    const oRdwr = 2; // O_RDWR (2 on macOS and Linux)
    const tciflush = 1; // TCIFLUSH on Darwin
    const tciflushLinux = 0; // TCIFLUSH on Linux

    path = '/dev/tty'.toNativeUtf8();
    final fd = open(path, oRdwr);
    if (fd >= 0) {
      tcflush(fd, Platform.isMacOS ? tciflush : tciflushLinux);
      close(fd);
    }
  } catch (_) {
    // Best-effort; never fail because we couldn't flush the tty.
  } finally {
    if (path != null) malloc.free(path);
  }
}

/// Flushes stdout (so any queued terminal query is actually sent), waits for the
/// reply to travel back, then drains the controlling terminal's input so the
/// reply can't leak into the shell as stray characters.
Future<void> settleTerminalInput() async {
  if (!(Platform.isMacOS || Platform.isLinux)) return;
  try {
    await stdout.flush();
  } catch (_) {}
  await Future<void>.delayed(const Duration(milliseconds: 200));
  drainTerminalInput();
}
