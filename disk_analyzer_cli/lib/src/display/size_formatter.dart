/// Human-readable size formatting utilities.
class SizeFormatter {
  static const _units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];

  /// Format bytes into a human-readable string (e.g., "1.5 GB").
  static String format(int bytes) {
    if (bytes == 0) return '0 B';
    var size = bytes.toDouble();
    var unitIndex = 0;
    while (size >= 1024 && unitIndex < _units.length - 1) {
      size /= 1024;
      unitIndex++;
    }
    if (unitIndex == 0) return '${size.toInt()} B';
    return '${size.toStringAsFixed(1)} ${_units[unitIndex]}';
  }

  /// Parse a size string like "100MB" or "1.5GB" into bytes.
  /// Returns null if the string cannot be parsed.
  static int? parse(String input) {
    final regex = RegExp(r'^(\d+(?:\.\d+)?)\s*(B|KB|MB|GB|TB|PB)$', caseSensitive: false);
    final match = regex.firstMatch(input.trim());
    if (match == null) return null;

    final value = double.parse(match.group(1)!);
    final unit = match.group(2)!.toUpperCase();
    final multiplier = switch (unit) {
      'B' => 1,
      'KB' => 1024,
      'MB' => 1024 * 1024,
      'GB' => 1024 * 1024 * 1024,
      'TB' => 1024 * 1024 * 1024 * 1024,
      'PB' => 1024 * 1024 * 1024 * 1024 * 1024,
      _ => 0,
    };
    return (value * multiplier).round();
  }
}
