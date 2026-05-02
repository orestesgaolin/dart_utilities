import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

typedef _LstatNative = Int32 Function(Pointer<Utf8> path, Pointer<Uint8> buf);
typedef _LstatDart = int Function(Pointer<Utf8> path, Pointer<Uint8> buf);

void main() {
  final dylib = DynamicLibrary.process();
  final lstat = dylib.lookupFunction<_LstatNative, _LstatDart>('lstat');

  // macOS stat struct offsets:
  // st_size:   offset 96, Int64
  // st_blocks: offset 104, Int64 (number of 512-byte blocks)
  
  final testFiles = [
    '/Users/dominik/.disk_cleaner/cache.db',
    '/Users/dominik/.zshrc',
  ];
  
  for (final path in testFiles) {
    if (!File(path).existsSync()) {
      print('$path: does not exist');
      continue;
    }
    
    final pathPtr = path.toNativeUtf8(allocator: malloc);
    final buf = malloc<Uint8>(256);
    
    final result = lstat(pathPtr.cast(), buf);
    if (result == 0) {
      final stSize = Pointer<Int64>.fromAddress(buf.address + 96).value;
      final stBlocks = Pointer<Int64>.fromAddress(buf.address + 104).value;
      final physicalSize = stBlocks * 512;
      final dartSize = File(path).statSync().size;
      
      print('$path:');
      print('  st_size (logical):     $stSize');
      print('  dart FileStat.size:    $dartSize');
      print('  st_blocks * 512:       $physicalSize');
      print('  ratio:                 ${stSize > 0 ? (physicalSize / stSize).toStringAsFixed(2) : "n/a"}x');
    }
    
    malloc.free(buf);
    malloc.free(pathPtr);
  }
  
  // Also verify with stat command
  for (final path in testFiles) {
    if (!File(path).existsSync()) continue;
    final result = Process.runSync('stat', ['-f', 'logical=%z blocks=%b blocksize=%k', path]);
    print('  stat cmd: ${result.stdout}');
  }
}
