import 'dart:math' as math;

import 'package:nocterm/nocterm.dart';

import '../storage/database.dart';
import '../storage/models.dart';
import 'size_formatter.dart';

/// Maximum number of rectangles to render — keeps rendering fast.
const _maxRects = 200;

/// A single rectangle in the treemap.
class _TreemapRect {
  final String path;
  final String name;
  final int size;
  final bool isDirectory;
  final Color color;
  final Color labelColor;
  // Layout coordinates (set by the layout algorithm)
  int x = 0, y = 0, w = 0, h = 0;

  _TreemapRect({
    required this.path,
    required this.name,
    required this.size,
    required this.isDirectory,
    required this.color,
    required this.labelColor,
  });
}

/// Color palette for folder groups — distinct hues at medium saturation.
const _folderHues = [
  (60, 140, 200), // blue
  (180, 120, 80), // brown/orange
  (80, 180, 120), // green
  (200, 100, 160), // pink
  (100, 180, 180), // teal
  (180, 140, 200), // purple
  (200, 180, 80), // gold
  (100, 160, 200), // sky
  (200, 120, 120), // salmon
  (120, 200, 160), // mint
  (160, 120, 180), // lavender
  (180, 200, 100), // lime
];

/// Generate a color for a folder at the given index.
Color _folderColor(int index) {
  final hue = _folderHues[index % _folderHues.length];
  return Color.fromRGB(hue.$1, hue.$2, hue.$3);
}

/// Generate a dimmer variant for files within that folder.
Color _fileColor(int folderIndex) {
  final hue = _folderHues[folderIndex % _folderHues.length];
  return Color.fromRGB(
    (hue.$1 * 0.6).round(),
    (hue.$2 * 0.6).round(),
    (hue.$3 * 0.6).round(),
  );
}

/// Builds treemap rectangles from DB entries using a single batch query.
/// Fetches entries at depth 0 and 1 relative to [parentPath], then builds
/// the tree in memory — avoids recursive DB round-trips.
List<_TreemapRect> _buildTreemapData({
  required DiskDatabase db,
  required int scanId,
  required String parentPath,
  required int totalArea,
  required int totalSize,
}) {
  // Single query: get direct children + grandchildren (2 levels)
  final allEntries = db.queryEntries(
    scanId: scanId,
    parentPath: parentPath,
    sortBy: 'size',
    descending: true,
  );

  // Also fetch grandchildren for large folders — batch all at once
  final largeFolders = <String>[];
  for (final e in allEntries) {
    if (e.isDirectory && totalSize > 0) {
      final cellEstimate = (e.size / totalSize * totalArea).round();
      if (cellEstimate >= 6) {
        largeFolders.add(e.path);
      }
    }
    // Stop early if we have enough top-level items
    if (largeFolders.length >= 30) break;
  }

  // Batch-fetch children for all large folders in one go
  final childrenByParent = <String, List<FileEntry>>{};
  if (largeFolders.isNotEmpty) {
    // Query children for each large folder — use a single prepared statement
    for (final folderPath in largeFolders) {
      final children = db.queryEntries(
        scanId: scanId,
        parentPath: folderPath,
        sortBy: 'size',
        descending: true,
        limit: 50, // Only top 50 children per folder
      );
      if (children.isNotEmpty) {
        childrenByParent[folderPath] = children;
      }
    }
  }

  // Build flat list of treemap rects
  final result = <_TreemapRect>[];
  var folderIdx = 0;

  for (final entry in allEntries) {
    if (totalSize <= 0 || entry.size <= 0) continue;
    if (result.length >= _maxRects) break;

    final cellEstimate = (entry.size / totalSize * totalArea).round();
    if (cellEstimate < 1) continue;

    final currentFolderIdx = folderIdx;
    if (entry.isDirectory) folderIdx++;

    // Try expanding this folder using pre-fetched children
    if (entry.isDirectory && childrenByParent.containsKey(entry.path)) {
      final children = childrenByParent[entry.path]!;
      var addedChildren = false;

      for (final child in children) {
        if (entry.size <= 0 || child.size <= 0) continue;
        if (result.length >= _maxRects) break;

        final childCells = (child.size / totalSize * totalArea).round();
        if (childCells < 1) continue;

        addedChildren = true;
        result.add(
          _TreemapRect(
            path: child.path,
            name: child.name,
            size: child.size,
            isDirectory: child.isDirectory,
            color: child.isDirectory
                ? _folderColor(currentFolderIdx)
                : _fileColor(currentFolderIdx),
            labelColor: Colors.white,
          ),
        );
      }

      if (addedChildren) continue;
    }

    // Leaf node
    result.add(
      _TreemapRect(
        path: entry.path,
        name: entry.name,
        size: entry.size,
        isDirectory: entry.isDirectory,
        color: entry.isDirectory
            ? _folderColor(currentFolderIdx)
            : _fileColor(currentFolderIdx),
        labelColor: Colors.white,
      ),
    );
  }

  return result;
}

/// Squarified treemap layout algorithm.
///
/// Lays out [items] within a rectangle of [width] x [height],
/// starting at ([x0], [y0]).
void _squarify(
  List<_TreemapRect> items,
  int x0,
  int y0,
  int width,
  int height,
) {
  if (items.isEmpty || width <= 0 || height <= 0) return;

  final totalSize = items.fold<int>(0, (s, r) => s + r.size);
  if (totalSize <= 0) return;

  if (items.length == 1) {
    items[0]
      ..x = x0
      ..y = y0
      ..w = width
      ..h = height;
    return;
  }

  // Layout along the shorter side
  final isHorizontal = width >= height;
  final sideLength = isHorizontal ? height : width;

  // Find the best split point (minimizing worst aspect ratio)
  var bestRatio = double.infinity;
  var bestSplit = 1;

  var runningSize = 0;
  for (var i = 0; i < items.length; i++) {
    runningSize += items[i].size;
    final fraction = runningSize / totalSize;
    final stripSize = isHorizontal
        ? (fraction * width).round()
        : (fraction * height).round();

    if (stripSize <= 0) continue;

    // Calculate worst aspect ratio in this strip
    var worstRatio = 0.0;
    for (var j = 0; j <= i; j++) {
      final itemFrac = items[j].size / runningSize;
      final itemLen = (itemFrac * sideLength).round();
      if (itemLen <= 0 || stripSize <= 0) continue;
      final ratio = itemLen > stripSize
          ? itemLen / stripSize
          : stripSize / itemLen;
      worstRatio = math.max(worstRatio, ratio);
    }

    if (worstRatio <= bestRatio) {
      bestRatio = worstRatio;
      bestSplit = i + 1;
    } else {
      break; // Aspect ratios getting worse, stop
    }
  }

  // Layout the first strip
  final stripItems = items.sublist(0, bestSplit);
  final restItems = items.sublist(bestSplit);
  final stripTotalSize = stripItems.fold<int>(0, (s, r) => s + r.size);
  final fraction = stripTotalSize / totalSize;

  int stripW, stripH;
  if (isHorizontal) {
    stripW = (fraction * width).round().clamp(1, width);
    stripH = height;
  } else {
    stripW = width;
    stripH = (fraction * height).round().clamp(1, height);
  }

  // Lay out items within the strip
  var offset = 0;
  for (var i = 0; i < stripItems.length; i++) {
    final itemFrac = stripItems[i].size / stripTotalSize;
    final isLast = i == stripItems.length - 1;

    if (isHorizontal) {
      final remaining = math.max(1, stripH - offset);
      final itemH = isLast
          ? remaining
          : (itemFrac * stripH).round().clamp(1, remaining);
      stripItems[i]
        ..x = x0
        ..y = y0 + offset
        ..w = stripW
        ..h = itemH;
      offset += itemH;
    } else {
      final remaining = math.max(1, stripW - offset);
      final itemW = isLast
          ? remaining
          : (itemFrac * stripW).round().clamp(1, remaining);
      stripItems[i]
        ..x = x0 + offset
        ..y = y0
        ..w = itemW
        ..h = stripH;
      offset += itemW;
    }
  }

  // Layout the remaining items in the leftover space
  if (restItems.isNotEmpty) {
    final restW = isHorizontal ? width - stripW : width;
    final restH = isHorizontal ? height : height - stripH;
    if (restW > 0 && restH > 0) {
      _squarify(
        restItems,
        isHorizontal ? x0 + stripW : x0,
        isHorizontal ? y0 : y0 + stripH,
        restW,
        restH,
      );
    }
  }
}

/// Treemap view component — renders an area-proportional chart of disk usage.
class TreemapView extends StatefulComponent {
  const TreemapView({
    required this.db,
    required this.scanId,
    required this.rootPath,
    required this.totalSize,
    this.onNavigate,
    super.key,
  });

  final DiskDatabase db;
  final int scanId;
  final String rootPath;
  final int totalSize;

  /// Called when user presses Enter on a directory rect.
  /// Passes the path and size of the folder to navigate into.
  final void Function(String path, int size)? onNavigate;

  @override
  State<TreemapView> createState() => TreemapViewState();
}

class TreemapViewState extends State<TreemapView> {
  List<_TreemapRect> _rects = [];
  int _hoveredIndex = -1;
  int _lastWidth = 0;
  int _lastHeight = 0;
  String _builtForPath = '';

  @override
  void initState() {
    super.initState();
    _buildLayout(80, 24); // Default, will be recalculated by LayoutBuilder
  }

  @override
  void didUpdateComponent(TreemapView oldComponent) {
    if (oldComponent.rootPath != component.rootPath ||
        oldComponent.totalSize != component.totalSize) {
      _builtForPath = ''; // Force rebuild
    }
  }

  void _buildLayout(int width, int height) {
    final chartHeight = height - 3;
    if (chartHeight <= 0 || width <= 0) return;

    _lastWidth = width;
    _lastHeight = chartHeight;
    _builtForPath = component.rootPath;

    final totalArea = width * chartHeight;

    final rects = _buildTreemapData(
      db: component.db,
      scanId: component.scanId,
      parentPath: component.rootPath,
      totalArea: totalArea,
      totalSize: component.totalSize,
    );

    rects.sort((a, b) => b.size.compareTo(a.size));
    _squarify(rects, 0, 0, width, chartHeight);

    _rects = rects;
    _hoveredIndex = rects.isNotEmpty ? 0 : -1;
  }

  /// Move highlight in the given direction. Returns true if handled.
  bool moveHighlight(LogicalKey key) {
    if (_rects.isEmpty) return false;

    if (key == LogicalKey.arrowRight ||
        key == LogicalKey.arrowLeft ||
        key == LogicalKey.arrowUp ||
        key == LogicalKey.arrowDown) {
      final next = _findNearest(key);
      if (next != null && next != _hoveredIndex) {
        setState(() => _hoveredIndex = next);
      }
      return true;
    }
    return false;
  }

  /// If the highlighted rect is a directory, fire onNavigate. Returns true if handled.
  bool enterHighlighted() {
    if (_hoveredIndex < 0 || _hoveredIndex >= _rects.length) return false;
    final rect = _rects[_hoveredIndex];
    if (rect.isDirectory && component.onNavigate != null) {
      component.onNavigate!(rect.path, rect.size);
      return true;
    }
    return false;
  }

  /// Find the nearest rect in the given arrow key direction.
  int? _findNearest(LogicalKey key) {
    if (_rects.isEmpty || _hoveredIndex < 0) return null;

    final cur = _rects[_hoveredIndex];
    final cx = cur.x + cur.w ~/ 2;
    final cy = cur.y + cur.h ~/ 2;

    int? bestIdx;
    var bestDist = double.infinity;

    for (var i = 0; i < _rects.length; i++) {
      if (i == _hoveredIndex) continue;
      final r = _rects[i];
      final rx = r.x + r.w ~/ 2;
      final ry = r.y + r.h ~/ 2;

      // Filter by direction
      final dx = rx - cx;
      final dy = ry - cy;

      bool valid;
      if (key == LogicalKey.arrowRight) {
        valid = dx > 0 && dx.abs() >= dy.abs();
      } else if (key == LogicalKey.arrowLeft) {
        valid = dx < 0 && dx.abs() >= dy.abs();
      } else if (key == LogicalKey.arrowDown) {
        valid = dy > 0 && dy.abs() >= dx.abs();
      } else {
        valid = dy < 0 && dy.abs() >= dx.abs();
      }

      if (!valid) continue;

      final dist = dx * dx + dy * dy;
      if (dist < bestDist) {
        bestDist = dist.toDouble();
        bestIdx = i;
      }
    }

    // Fallback: if strict direction found nothing, try any rect in that half
    if (bestIdx == null) {
      for (var i = 0; i < _rects.length; i++) {
        if (i == _hoveredIndex) continue;
        final r = _rects[i];
        final rx = r.x + r.w ~/ 2;
        final ry = r.y + r.h ~/ 2;
        final dx = rx - cx;
        final dy = ry - cy;

        bool valid;
        if (key == LogicalKey.arrowRight) {
          valid = dx > 0;
        } else if (key == LogicalKey.arrowLeft) {
          valid = dx < 0;
        } else if (key == LogicalKey.arrowDown) {
          valid = dy > 0;
        } else {
          valid = dy < 0;
        }

        if (!valid) continue;
        final dist = dx * dx + dy * dy;
        if (dist < bestDist) {
          bestDist = dist.toDouble();
          bestIdx = i;
        }
      }
    }

    return bestIdx;
  }

  @override
  Component build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.toInt();
        final height = constraints.maxHeight.toInt();
        final chartHeight = height - 3;

        // Rebuild layout if size changed or path changed
        if (_rects.isEmpty ||
            width != _lastWidth ||
            chartHeight != _lastHeight ||
            _builtForPath != component.rootPath) {
          _buildLayout(width, height);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildInfoBar(width),
            Divider(style: DividerStyle.single, color: Colors.gray),
            Expanded(child: _buildChart(width, chartHeight)),
          ],
        );
      },
    );
  }

  Component _buildInfoBar(int width) {
    final info = _hoveredIndex >= 0 && _hoveredIndex < _rects.length
        ? _rects[_hoveredIndex]
        : null;

    final label = info != null
        ? '${info.isDirectory ? "\u{1f4c1}" : "\u{1f4c4}"} ${info.path}  '
              '${SizeFormatter.format(info.size)}  '
              '(${(info.size / component.totalSize * 100).toStringAsFixed(1)}%)'
        : '\u{1f4ca} Treemap: ${component.rootPath}';

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 1),
      child: Text(
        label,
        style: TextStyle(color: Colors.white),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      ),
    );
  }

  Component _buildChart(int width, int height) {
    if (_rects.isEmpty || width <= 0 || height <= 0) {
      return Center(
        child: Text('No data to display', style: TextStyle(color: Colors.gray)),
      );
    }

    // Build row spans directly from rects (no intermediate grid)
    // For each row, collect (rectIndex, x, length) spans sorted by x
    final rowSpans = List.generate(
      height,
      (_) => <({int idx, int x, int len})>[],
    );

    for (var i = 0; i < _rects.length; i++) {
      final r = _rects[i];
      for (var y = r.y; y < r.y + r.h && y < height; y++) {
        rowSpans[y].add((idx: i, x: r.x, len: r.w));
      }
    }

    final rows = <Component>[];
    for (var y = 0; y < height; y++) {
      final spans = rowSpans[y];
      if (spans.isEmpty) {
        rows.add(Text(' ' * width));
        continue;
      }
      spans.sort((a, b) => a.x.compareTo(b.x));
      rows.add(_buildRowFromSpans(spans, y, width));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }

  Component _buildRowFromSpans(
    List<({int idx, int x, int len})> spans,
    int y,
    int width,
  ) {
    final children = <Component>[];
    var cursor = 0;

    for (final (:idx, :x, :len) in spans) {
      // Fill gap before this span
      if (x > cursor) {
        children.add(Text(' ' * (x - cursor)));
      }

      final rect = _rects[idx];
      final isHovered = idx == _hoveredIndex;
      final spanLen = math.min(len, width - x);

      // Determine text content for this span
      String text;
      if (rect.h >= 1 && rect.w >= 3 && y == rect.y && x == rect.x) {
        final label = _labelForRect(rect);
        text = label.length <= spanLen
            ? label.padRight(spanLen)
            : label.substring(0, spanLen);
      } else if (rect.h >= 2 && rect.w >= 5 && y == rect.y + 1 && x == rect.x) {
        final sizeStr = SizeFormatter.format(rect.size);
        text = sizeStr.length <= spanLen
            ? sizeStr.padRight(spanLen)
            : sizeStr.substring(0, spanLen);
      } else {
        text = '\u{2588}' * spanLen;
      }

      final bgColor = isHovered ? _brighten(rect.color, 0.4) : rect.color;
      final fgColor = isHovered ? Colors.white : rect.labelColor;
      final isLabelRow = y == rect.y || (y == rect.y + 1 && rect.h >= 2);

      children.add(
        Text(
          text,
          style: TextStyle(
            backgroundColor: bgColor,
            color: isLabelRow ? fgColor : bgColor,
          ),
        ),
      );

      cursor = x + spanLen;
    }

    // Fill trailing gap
    if (cursor < width) {
      children.add(Text(' ' * (width - cursor)));
    }

    return Row(children: children);
  }

  String _labelForRect(_TreemapRect rect) {
    final icon = rect.isDirectory ? '\u{25b8}' : '';
    return '$icon${rect.name}';
  }

  Color _brighten(Color c, double amount) {
    // Simple brighten: lerp toward white
    return Color.fromRGB(
      (c.red + (255 - c.red) * amount).round().clamp(0, 255),
      (c.green + (255 - c.green) * amount).round().clamp(0, 255),
      (c.blue + (255 - c.blue) * amount).round().clamp(0, 255),
    );
  }
}
