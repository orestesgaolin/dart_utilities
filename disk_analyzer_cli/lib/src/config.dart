import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Configuration for the disk analyzer.
///
/// Persisted to `~/.disk_cleaner/config.json`.
class AnalyzerConfig {
  /// Directory names that should not be recursed into during scanning.
  /// Only the folder entry with its total size (via du) is stored.
  List<String> collapsedDirs;

  AnalyzerConfig({
    List<String>? collapsedDirs,
  }) : collapsedDirs = collapsedDirs ?? _defaultCollapsedDirs.toList();

  static const _defaultCollapsedDirs = [
    'node_modules',
    '.git',
  ];

  static String get _configPath {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return p.join(home, '.disk_cleaner', 'config.json');
  }

  /// Load config from disk, or return defaults if not found.
  factory AnalyzerConfig.load() {
    final file = File(_configPath);
    if (!file.existsSync()) return AnalyzerConfig();

    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return AnalyzerConfig(
        collapsedDirs: (json['collapsed_dirs'] as List<dynamic>?)
            ?.cast<String>()
            .toList(),
      );
    } catch (_) {
      return AnalyzerConfig();
    }
  }

  /// Persist current config to disk.
  void save() {
    final file = File(_configPath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'collapsed_dirs': collapsedDirs,
      }),
    );
  }

  /// Whether a directory name should be collapsed (not recursed into).
  bool shouldCollapse(String dirName) {
    return collapsedDirs.contains(dirName);
  }
}
