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

/// The terminal settings captured before the TUI started, used to restore the
/// exact original state on exit.
String? _savedTtyState;

/// Snapshots the controlling terminal's settings (`stty -g`) so they can be
/// restored verbatim later. Call once, before `runApp`.
void captureTerminalState() {
  if (!(Platform.isMacOS || Platform.isLinux)) return;
  try {
    final result = Process.runSync('sh', ['-c', 'stty -g < /dev/tty']);
    if (result.exitCode == 0) {
      final state = (result.stdout as String).trim();
      if (state.isNotEmpty) _savedTtyState = state;
    }
  } catch (_) {
    // Best-effort.
  }
}

/// Restores the terminal to the exact state captured by [captureTerminalState]
/// (echo, canonical input, signal handling / Ctrl+C, output post-processing /
/// `ONLCR`). Falls back to `stty sane` if no snapshot was taken.
///
/// Dart's stdin API only restores input flags, and nocterm / `git mergetool`
/// can leave the terminal with signals or output processing disabled — which
/// breaks Ctrl+C and makes shell output "stairstep". Restoring the full
/// snapshot fixes all of it at once.
Future<void> restoreTerminalModes() async {
  if (!(Platform.isMacOS || Platform.isLinux)) return;
  final saved = _savedTtyState;
  final cmd = saved != null ? 'stty $saved < /dev/tty' : 'stty sane < /dev/tty';
  try {
    await Process.run('sh', ['-c', cmd]);
  } catch (_) {
    // Best-effort.
  }
}

/// Flushes stdout (so any queued terminal query is actually sent), waits for the
/// reply to travel back, drains the controlling terminal's input so the reply
/// can't leak into the shell, and restores sane terminal modes.
Future<void> settleTerminalInput() async {
  if (!(Platform.isMacOS || Platform.isLinux)) return;
  await restoreTerminalModes();
  try {
    await stdout.flush();
  } catch (_) {}
  await Future<void>.delayed(const Duration(milliseconds: 200));
  drainTerminalInput();
}
