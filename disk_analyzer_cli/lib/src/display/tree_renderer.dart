import '../storage/models.dart';
import 'size_formatter.dart';

/// Renders a tree view of disk usage with size bars and percentages.
class TreeRenderer {
  static const _barWidth = 20;
  static const _barFull = '█';
  static const _barEmpty = '░';

  /// Render a list of entries as a tree view.
  ///
  /// [entries] should be the children of a single parent, sorted by size desc.
  /// [totalSize] is used to compute percentages.
  /// [indent] is the current indentation level.
  static String renderTree({
    required List<FileEntry> entries,
    required int totalSize,
    int indent = 0,
    int? maxItems,
  }) {
    final buf = StringBuffer();
    final items = maxItems != null && entries.length > maxItems
        ? entries.take(maxItems).toList()
        : entries;
    final remaining = maxItems != null ? entries.length - items.length : 0;

    for (var i = 0; i < items.length; i++) {
      final entry = items[i];
      final isLast = i == items.length - 1 && remaining == 0;
      final prefix = _buildPrefix(indent, isLast);
      final icon = entry.isDirectory ? '📁' : '📄';
      final size = SizeFormatter.format(entry.size);
      final pct = totalSize > 0
          ? (entry.size / totalSize * 100).toStringAsFixed(1)
          : '0.0';
      final bar = _buildBar(entry.size, totalSize);

      buf.writeln('$prefix$icon ${entry.name.padRight(30)} $size  $bar  $pct%');
    }

    if (remaining > 0) {
      final prefix = _buildPrefix(indent, true);
      buf.writeln('$prefix   ... and $remaining more items');
    }

    return buf.toString();
  }

  /// Render a summary header for a scan.
  static String renderHeader({
    required String rootPath,
    required int totalSize,
    required int fileCount,
    required int dirCount,
    required DateTime scannedAt,
  }) {
    final buf = StringBuffer();
    buf.writeln('');
    buf.writeln('  📊 Disk Usage: $rootPath');
    buf.writeln('  ${'─' * 60}');
    buf.writeln('  Total size:  ${SizeFormatter.format(totalSize)}');
    buf.writeln('  Files:       $fileCount');
    buf.writeln('  Directories: $dirCount');
    buf.writeln('  Scanned at:  ${_formatDate(scannedAt)}');
    buf.writeln('  ${'─' * 60}');
    buf.writeln('');
    return buf.toString();
  }

  static String _buildPrefix(int indent, bool isLast) {
    if (indent == 0) return '  ';
    final buf = StringBuffer('  ');
    for (var i = 0; i < indent - 1; i++) {
      buf.write('│   ');
    }
    buf.write(isLast ? '└── ' : '├── ');
    return buf.toString();
  }

  static String _buildBar(int size, int totalSize) {
    if (totalSize == 0) return _barEmpty * _barWidth;
    final ratio = size / totalSize;
    final filled = (ratio * _barWidth).round().clamp(0, _barWidth);
    return _barFull * filled + _barEmpty * (_barWidth - filled);
  }

  static String _formatDate(DateTime dt) {
    return '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)} '
        '${_pad(dt.hour)}:${_pad(dt.minute)}:${_pad(dt.second)}';
  }

  static String _pad(int n) => n.toString().padLeft(2, '0');
}
