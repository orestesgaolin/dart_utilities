import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:disk_analyzer_cli/disk_analyzer_cli.dart';
import 'package:path/path.dart' as p;

const _defaultProfiles = ['smoke'];
const _defaultThreads = [1];
const _jsonEncoder = JsonEncoder.withIndent('  ');

Future<void> main(List<String> arguments) async {
  final parser = _buildParser();
  late ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln('');
    stderr.writeln(parser.usage);
    exitCode = 64;
    return;
  }

  if (args.flag('help')) {
    stdout.writeln('Benchmark disk_analyzer_cli scanning against ncdu.');
    stdout.writeln('');
    stdout.writeln(parser.usage);
    return;
  }

  final config = _BenchmarkConfig.fromArgs(args);
  final targets = <String, String>{};
  final results = <_BenchmarkResult>[];

  for (final profile in config.profiles) {
    final fixturePath = await _ensureFixture(
      profile: profile,
      fixtureRoot: config.fixtureRoot,
      recreate: config.recreateFixtures,
    );
    targets[profile] = fixturePath;
  }

  for (final externalPath in config.paths) {
    final directory = Directory(externalPath);
    if (!directory.existsSync()) {
      throw FormatException('Benchmark path does not exist: $externalPath');
    }
    targets[_targetName(externalPath)] = directory.resolveSymbolicLinksSync();
  }

  final ncduVersion = config.skipNcdu ? null : await _detectNcduVersion();
  if (!config.skipNcdu && ncduVersion == null) {
    stdout.writeln('ncdu was not found; ncdu comparison rows will be skipped.');
  }

  for (final entry in targets.entries) {
    final profile = entry.key;
    final fixturePath = entry.value;
    stdout.writeln('Target $profile: $fixturePath');

    for (var iteration = 1; iteration <= config.iterations; iteration++) {
      results.add(
        await _runScannerOnly(
          profile: profile,
          fixturePath: fixturePath,
          iteration: iteration,
        ),
      );

      results.add(
        await _runSqliteScan(
          profile: profile,
          fixturePath: fixturePath,
          iteration: iteration,
          batchSize: config.batchSize,
          scratchRoot: config.scratchRoot,
        ),
      );

      if (config.includeCli) {
        results.add(
          await _runCliScan(
            profile: profile,
            fixturePath: fixturePath,
            iteration: iteration,
            batchSize: config.batchSize,
            scratchRoot: config.scratchRoot,
          ),
        );
      }

      if (ncduVersion == null) {
        results.addAll(
          _skippedNcduRows(
            profile: profile,
            iteration: iteration,
            threads: config.ncduThreads,
            reason: config.skipNcdu
                ? 'disabled by --skip-ncdu'
                : 'ncdu not found',
          ),
        );
      } else {
        for (final threads in config.ncduThreads) {
          results.add(
            await _runNcdu(
              profile: profile,
              fixturePath: fixturePath,
              iteration: iteration,
              threads: threads,
              binaryExport: false,
            ),
          );
          results.add(
            await _runNcdu(
              profile: profile,
              fixturePath: fixturePath,
              iteration: iteration,
              threads: threads,
              binaryExport: true,
            ),
          );
        }
      }
    }
  }

  final outputPath = config.outputPath ?? _defaultOutputPath();
  final outputFile = File(outputPath);
  outputFile.parent.createSync(recursive: true);
  final report = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'config': config.toJson(),
    'environment': await _environment(ncduVersion),
    'targets': targets,
    'summary': _summarize(results),
    'results': results.map((result) => result.toJson()).toList(),
  };
  outputFile.writeAsStringSync('${_jsonEncoder.convert(report)}\n');

  final markdownPath = p.setExtension(outputPath, '.md');
  File(markdownPath).writeAsStringSync(_renderMarkdown(report));

  stdout.writeln('');
  stdout.writeln('Wrote benchmark report: $outputPath');
  stdout.writeln('Wrote benchmark summary: $markdownPath');
}

ArgParser _buildParser() {
  return ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.')
    ..addOption(
      'profiles',
      defaultsTo: _defaultProfiles.join(','),
      help:
          'Comma-separated fixture profiles: smoke, wide, deep, mixed, hardlinks.',
    )
    ..addOption(
      'paths',
      help:
          'Comma-separated existing directories to benchmark, for example /tmp.',
    )
    ..addOption(
      'iterations',
      defaultsTo: '3',
      help: 'Number of timed runs for each benchmark target.',
    )
    ..addOption(
      'fixture-root',
      defaultsTo: p.join('benchmark', '.fixtures'),
      help: 'Directory where generated fixtures are stored.',
    )
    ..addOption(
      'scratch-root',
      defaultsTo: p.join('benchmark', '.tmp'),
      help: 'Directory for temporary benchmark databases and HOME directories.',
    )
    ..addFlag(
      'recreate-fixtures',
      defaultsTo: false,
      help: 'Delete and regenerate selected fixture directories.',
    )
    ..addOption(
      'output',
      help: 'JSON report path. Defaults to benchmark/results/<timestamp>.json.',
    )
    ..addOption(
      'batch-size',
      defaultsTo: '5000',
      help: 'SQLite insert batch size for app-sqlite and CLI runs.',
    )
    ..addFlag(
      'include-cli',
      defaultsTo: true,
      help: 'Include dart run bin/disk_analyzer_cli.dart scan runs.',
    )
    ..addFlag(
      'skip-ncdu',
      defaultsTo: false,
      help: 'Skip ncdu comparison runs.',
    )
    ..addOption(
      'ncdu-threads',
      defaultsTo: _defaultThreads.join(','),
      help: 'Comma-separated thread counts for ncdu --threads.',
    );
}

class _BenchmarkConfig {
  final List<String> profiles;
  final List<String> paths;
  final int iterations;
  final String fixtureRoot;
  final String scratchRoot;
  final bool recreateFixtures;
  final String? outputPath;
  final int batchSize;
  final bool includeCli;
  final bool skipNcdu;
  final List<int> ncduThreads;

  _BenchmarkConfig({
    required this.profiles,
    required this.paths,
    required this.iterations,
    required this.fixtureRoot,
    required this.scratchRoot,
    required this.recreateFixtures,
    required this.outputPath,
    required this.batchSize,
    required this.includeCli,
    required this.skipNcdu,
    required this.ncduThreads,
  });

  factory _BenchmarkConfig.fromArgs(ArgResults args) {
    final profiles = _parseCsv(
      args.option('profiles')!,
    ).map((profile) => profile.toLowerCase()).toList(growable: false);
    final selectedProfiles = args.wasParsed('profiles')
        ? profiles
        : (profiles.isEmpty ? _defaultProfiles : profiles);
    final unknownProfiles = profiles.where(
      (profile) => !_fixtureSpecs.containsKey(profile),
    );
    if (unknownProfiles.isNotEmpty) {
      throw FormatException(
        'Unknown fixture profile: ${unknownProfiles.join(', ')}',
      );
    }

    final iterations = _positiveInt(args.option('iterations')!, 'iterations');
    final paths = _parseCsv(args.option('paths') ?? '');
    if (selectedProfiles.isEmpty && paths.isEmpty) {
      throw FormatException('Select at least one --profiles value or --paths.');
    }
    final batchSize = _positiveInt(args.option('batch-size')!, 'batch-size');
    final ncduThreads = _parseCsv(args.option('ncdu-threads')!)
        .map((value) => _positiveInt(value, 'ncdu-threads'))
        .toList(growable: false);

    return _BenchmarkConfig(
      profiles: selectedProfiles,
      paths: paths,
      iterations: iterations,
      fixtureRoot: args.option('fixture-root')!,
      scratchRoot: args.option('scratch-root')!,
      recreateFixtures: args.flag('recreate-fixtures'),
      outputPath: args.option('output'),
      batchSize: batchSize,
      includeCli: args.flag('include-cli'),
      skipNcdu: args.flag('skip-ncdu'),
      ncduThreads: ncduThreads.isEmpty ? _defaultThreads : ncduThreads,
    );
  }

  Map<String, Object?> toJson() => {
    'profiles': profiles,
    'paths': paths,
    'iterations': iterations,
    'fixtureRoot': fixtureRoot,
    'scratchRoot': scratchRoot,
    'recreateFixtures': recreateFixtures,
    'batchSize': batchSize,
    'includeCli': includeCli,
    'skipNcdu': skipNcdu,
    'ncduThreads': ncduThreads,
  };
}

class _FixtureSpec {
  final int depth;
  final int dirsPerLevel;
  final int filesPerDir;
  final int baseFileSize;
  final bool variableSizes;
  final bool hardlinks;

  const _FixtureSpec({
    required this.depth,
    required this.dirsPerLevel,
    required this.filesPerDir,
    required this.baseFileSize,
    this.variableSizes = false,
    this.hardlinks = false,
  });

  Map<String, Object?> toJson() => {
    'depth': depth,
    'dirsPerLevel': dirsPerLevel,
    'filesPerDir': filesPerDir,
    'baseFileSize': baseFileSize,
    'variableSizes': variableSizes,
    'hardlinks': hardlinks,
  };
}

const _fixtureSpecs = {
  'smoke': _FixtureSpec(
    depth: 2,
    dirsPerLevel: 2,
    filesPerDir: 3,
    baseFileSize: 1024,
  ),
  'wide': _FixtureSpec(
    depth: 2,
    dirsPerLevel: 24,
    filesPerDir: 12,
    baseFileSize: 256,
    variableSizes: true,
  ),
  'deep': _FixtureSpec(
    depth: 32,
    dirsPerLevel: 1,
    filesPerDir: 2,
    baseFileSize: 128,
  ),
  'mixed': _FixtureSpec(
    depth: 4,
    dirsPerLevel: 4,
    filesPerDir: 8,
    baseFileSize: 512,
    variableSizes: true,
  ),
  'hardlinks': _FixtureSpec(
    depth: 2,
    dirsPerLevel: 3,
    filesPerDir: 4,
    baseFileSize: 1024,
    hardlinks: true,
  ),
};

class _BenchmarkResult {
  final String profile;
  final String label;
  final int iteration;
  final int elapsedMs;
  final int exitCode;
  final bool skipped;
  final String? skipReason;
  final String command;
  final int? totalSize;
  final int? fileCount;
  final int? dirCount;
  final int? entriesWritten;
  final String stdoutTail;
  final String stderrTail;

  _BenchmarkResult({
    required this.profile,
    required this.label,
    required this.iteration,
    required this.elapsedMs,
    required this.exitCode,
    required this.skipped,
    required this.skipReason,
    required this.command,
    required this.totalSize,
    required this.fileCount,
    required this.dirCount,
    required this.entriesWritten,
    required this.stdoutTail,
    required this.stderrTail,
  });

  factory _BenchmarkResult.skipped({
    required String profile,
    required String label,
    required int iteration,
    required String reason,
  }) {
    return _BenchmarkResult(
      profile: profile,
      label: label,
      iteration: iteration,
      elapsedMs: 0,
      exitCode: 0,
      skipped: true,
      skipReason: reason,
      command: '',
      totalSize: null,
      fileCount: null,
      dirCount: null,
      entriesWritten: null,
      stdoutTail: '',
      stderrTail: '',
    );
  }

  Map<String, Object?> toJson() => {
    'profile': profile,
    'label': label,
    'iteration': iteration,
    'elapsedMs': elapsedMs,
    'exitCode': exitCode,
    'skipped': skipped,
    'skipReason': skipReason,
    'command': command,
    'totalSize': totalSize,
    'fileCount': fileCount,
    'dirCount': dirCount,
    'entriesWritten': entriesWritten,
    'stdoutTail': stdoutTail,
    'stderrTail': stderrTail,
  };
}

Future<String> _ensureFixture({
  required String profile,
  required String fixtureRoot,
  required bool recreate,
}) async {
  final spec = _fixtureSpecs[profile]!;
  final root = Directory(p.join(fixtureRoot, profile));
  final manifest = File(p.join(root.path, '.fixture.json'));

  if (recreate && root.existsSync()) {
    root.deleteSync(recursive: true);
  }

  if (manifest.existsSync()) {
    return root.resolveSymbolicLinksSync();
  }

  root.createSync(recursive: true);
  var fileIndex = 0;
  void createLevel(Directory dir, int remainingDepth) {
    for (var fileNumber = 0; fileNumber < spec.filesPerDir; fileNumber++) {
      final size = spec.variableSizes
          ? spec.baseFileSize * (1 + ((fileIndex + fileNumber) % 11))
          : spec.baseFileSize;
      final bytes = Uint8List(size);
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = (fileIndex + i) % 251;
      }
      File(
        p.join(dir.path, 'file_${fileIndex.toString().padLeft(6, '0')}.dat'),
      ).writeAsBytesSync(bytes, flush: false);
      fileIndex++;
    }

    if (remainingDepth == 0) return;

    for (var dirNumber = 0; dirNumber < spec.dirsPerLevel; dirNumber++) {
      final child = Directory(
        p.join(
          dir.path,
          'dir_${remainingDepth.toString().padLeft(2, '0')}_'
          '${dirNumber.toString().padLeft(3, '0')}',
        ),
      );
      child.createSync(recursive: true);
      createLevel(child, remainingDepth - 1);
    }
  }

  createLevel(root, spec.depth);

  var hardlinksCreated = 0;
  if (spec.hardlinks) {
    hardlinksCreated = _createHardlinks(root);
  }

  manifest.writeAsStringSync(
    '${_jsonEncoder.convert({'profile': profile, 'spec': spec.toJson(), 'filesCreated': fileIndex, 'hardlinksCreated': hardlinksCreated, 'createdAt': DateTime.now().toUtc().toIso8601String()})}\n',
  );

  return root.resolveSymbolicLinksSync();
}

int _createHardlinks(Directory root) {
  if (!Platform.isMacOS && !Platform.isLinux) return 0;

  final source = File(p.join(root.path, 'file_000000.dat'));
  if (!source.existsSync()) return 0;

  var created = 0;
  for (var i = 0; i < 8; i++) {
    final target = p.join(
      root.path,
      'hardlink_${i.toString().padLeft(2, '0')}.dat',
    );
    final result = Process.runSync('ln', [source.path, target]);
    if (result.exitCode == 0) created++;
  }
  return created;
}

Future<_BenchmarkResult> _runScannerOnly({
  required String profile,
  required String fixturePath,
  required int iteration,
}) async {
  var entries = 0;
  final scanner = DiskScanner(collapsedDirs: const []);
  final stopwatch = Stopwatch()..start();
  final result = await scanner.scan(fixturePath, onEntry: (_) => entries++);
  stopwatch.stop();

  _printRun(
    profile,
    'scanner-only',
    iteration,
    stopwatch.elapsedMilliseconds,
    0,
  );
  return _BenchmarkResult(
    profile: profile,
    label: 'scanner-only',
    iteration: iteration,
    elapsedMs: stopwatch.elapsedMilliseconds,
    exitCode: 0,
    skipped: false,
    skipReason: null,
    command: 'DiskScanner.scan',
    totalSize: result.totalSize,
    fileCount: result.fileCount,
    dirCount: result.dirCount,
    entriesWritten: entries,
    stdoutTail: '',
    stderrTail: result.errors.take(10).join('\n'),
  );
}

Future<_BenchmarkResult> _runSqliteScan({
  required String profile,
  required String fixturePath,
  required int iteration,
  required int batchSize,
  required String scratchRoot,
}) async {
  final tempDir = _createScratchDir(scratchRoot, 'db');
  DiskDatabase? db;
  final stopwatch = Stopwatch()..start();
  try {
    db = DiskDatabase.open(p.join(tempDir.path, 'cache.db'));
    final scanId = db.createScan(rootPath: fixturePath);
    final writer = db.batchWriter(scanId, batchSize: batchSize);
    writer.add(
      FileEntry(
        path: fixturePath,
        isDirectory: true,
        size: 0,
        depth: 0,
        parentPath: null,
      ),
    );

    final scanner = DiskScanner(collapsedDirs: const []);
    final result = await scanner.scan(fixturePath, onEntry: writer.add);
    writer.dispose();
    db.updateEntrySize(scanId, fixturePath, result.totalSize);
    db.updateScan(
      scanId: scanId,
      totalSize: result.totalSize,
      fileCount: result.fileCount,
      dirCount: result.dirCount,
      status: result.timedOut ? 'interrupted' : 'complete',
    );
    stopwatch.stop();

    _printRun(
      profile,
      'app-sqlite',
      iteration,
      stopwatch.elapsedMilliseconds,
      0,
    );
    return _BenchmarkResult(
      profile: profile,
      label: 'app-sqlite',
      iteration: iteration,
      elapsedMs: stopwatch.elapsedMilliseconds,
      exitCode: 0,
      skipped: false,
      skipReason: null,
      command:
          'DiskScanner.scan + DiskDatabase.batchWriter(batchSize: $batchSize)',
      totalSize: result.totalSize,
      fileCount: result.fileCount,
      dirCount: result.dirCount,
      entriesWritten: writer.totalWritten,
      stdoutTail: '',
      stderrTail: result.errors.take(10).join('\n'),
    );
  } finally {
    db?.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  }
}

Future<_BenchmarkResult> _runCliScan({
  required String profile,
  required String fixturePath,
  required int iteration,
  required int batchSize,
  required String scratchRoot,
}) async {
  final home = _createScratchDir(scratchRoot, 'home');
  final args = [
    'run',
    'bin/disk_analyzer_cli.dart',
    'scan',
    fixturePath,
    '--batch-size',
    '$batchSize',
  ];
  try {
    final result = await _timedProcess(
      'dart',
      args,
      environment: {...Platform.environment, 'HOME': home.path},
    );
    final parsed = _parseCliSummary(result.stdoutText);
    _printRun(
      profile,
      'cli-dart-run',
      iteration,
      result.elapsedMs,
      result.exitCode,
    );
    return _BenchmarkResult(
      profile: profile,
      label: 'cli-dart-run',
      iteration: iteration,
      elapsedMs: result.elapsedMs,
      exitCode: result.exitCode,
      skipped: false,
      skipReason: null,
      command: 'dart ${args.join(' ')}',
      totalSize: null,
      fileCount: parsed['files'],
      dirCount: parsed['directories'],
      entriesWritten: parsed['dbWrites'],
      stdoutTail: _tail(result.stdoutText),
      stderrTail: _tail(result.stderrText),
    );
  } finally {
    if (home.existsSync()) {
      home.deleteSync(recursive: true);
    }
  }
}

Future<_BenchmarkResult> _runNcdu({
  required String profile,
  required String fixturePath,
  required int iteration,
  required int threads,
  required bool binaryExport,
}) async {
  final label = binaryExport ? 'ncdu-bin-t$threads' : 'ncdu-json-t$threads';
  final args = [
    '--ignore-config',
    '-0',
    '-x',
    '--threads',
    '$threads',
    binaryExport ? '-O' : '-o',
    _nullDevice,
    fixturePath,
  ];

  final result = await _timedProcess('ncdu', args);
  _printRun(profile, label, iteration, result.elapsedMs, result.exitCode);
  return _BenchmarkResult(
    profile: profile,
    label: label,
    iteration: iteration,
    elapsedMs: result.elapsedMs,
    exitCode: result.exitCode,
    skipped: false,
    skipReason: null,
    command: 'ncdu ${args.join(' ')}',
    totalSize: null,
    fileCount: null,
    dirCount: null,
    entriesWritten: null,
    stdoutTail: _tail(result.stdoutText),
    stderrTail: _tail(result.stderrText),
  );
}

List<_BenchmarkResult> _skippedNcduRows({
  required String profile,
  required int iteration,
  required List<int> threads,
  required String reason,
}) {
  return [
    for (final threadCount in threads) ...[
      _BenchmarkResult.skipped(
        profile: profile,
        label: 'ncdu-json-t$threadCount',
        iteration: iteration,
        reason: reason,
      ),
      _BenchmarkResult.skipped(
        profile: profile,
        label: 'ncdu-bin-t$threadCount',
        iteration: iteration,
        reason: reason,
      ),
    ],
  ];
}

Future<String?> _detectNcduVersion() async {
  try {
    final result = await Process.run('ncdu', ['--version']);
    if (result.exitCode != 0) return null;
    return '${result.stdout}'.trim();
  } on IOException {
    return null;
  }
}

Future<Map<String, Object?>> _environment(String? ncduVersion) async {
  final dartVersion = await Process.run('dart', ['--version']);
  return {
    'platform': Platform.operatingSystem,
    'platformVersion': Platform.operatingSystemVersion,
    'dartVersion': '${dartVersion.stderr}${dartVersion.stdout}'.trim(),
    'ncduVersion': ncduVersion,
  };
}

Map<String, int> _parseCliSummary(String stdoutText) {
  int valueFor(String label) {
    final match = RegExp('$label:\\s+(\\d+)').firstMatch(stdoutText);
    return match == null ? 0 : int.parse(match.group(1)!);
  }

  return {
    'files': valueFor('Files'),
    'directories': valueFor('Directories'),
    'dbWrites': valueFor('DB writes'),
  };
}

Map<String, Object?> _summarize(List<_BenchmarkResult> results) {
  final groups = <String, List<_BenchmarkResult>>{};
  for (final result in results) {
    if (result.skipped || result.exitCode != 0) continue;
    groups
        .putIfAbsent('${result.profile}:${result.label}', () => [])
        .add(result);
  }

  final rows =
      groups.entries.map((entry) {
        final times = entry.value.map((result) => result.elapsedMs).toList()
          ..sort();
        final first = entry.value.first;
        return {
          'profile': first.profile,
          'label': first.label,
          'runs': times.length,
          'medianMs': _median(times),
          'minMs': times.first,
          'maxMs': times.last,
          'fileCount': first.fileCount,
          'dirCount': first.dirCount,
          'entriesWritten': first.entriesWritten,
        };
      }).toList()..sort((a, b) {
        final profileCompare = '${a['profile']}'.compareTo('${b['profile']}');
        if (profileCompare != 0) return profileCompare;
        return '${a['label']}'.compareTo('${b['label']}');
      });

  return {'rows': rows};
}

String _renderMarkdown(Map<String, Object?> report) {
  final buffer = StringBuffer()
    ..writeln('# Scan Benchmark')
    ..writeln()
    ..writeln('- Generated: ${report['generatedAt']}')
    ..writeln('- Platform: ${(report['environment'] as Map)['platform']}')
    ..writeln()
    ..writeln(
      '| Profile | Target | Runs | Median ms | Min ms | Max ms | Files | Dirs | Entries |',
    )
    ..writeln('| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |');

  final summary = report['summary'] as Map<String, Object?>;
  final rows = summary['rows'] as List<Object?>;
  for (final rowObject in rows) {
    final row = rowObject as Map<String, Object?>;
    buffer.writeln(
      '| ${row['profile']} | ${row['label']} | ${row['runs']} | '
      '${row['medianMs']} | ${row['minMs']} | ${row['maxMs']} | '
      '${row['fileCount'] ?? ''} | ${row['dirCount'] ?? ''} | '
      '${row['entriesWritten'] ?? ''} |',
    );
  }

  buffer
    ..writeln()
    ..writeln(
      'Rows with non-zero exit codes are preserved in the JSON report but excluded from this summary table.',
    );
  return buffer.toString();
}

Future<_ProcessMeasurement> _timedProcess(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
}) async {
  final stopwatch = Stopwatch()..start();
  final result = await Process.run(
    executable,
    arguments,
    environment: environment,
    runInShell: false,
  );
  stopwatch.stop();
  return _ProcessMeasurement(
    exitCode: result.exitCode,
    elapsedMs: stopwatch.elapsedMilliseconds,
    stdoutText: '${result.stdout}',
    stderrText: '${result.stderr}',
  );
}

class _ProcessMeasurement {
  final int exitCode;
  final int elapsedMs;
  final String stdoutText;
  final String stderrText;

  _ProcessMeasurement({
    required this.exitCode,
    required this.elapsedMs,
    required this.stdoutText,
    required this.stderrText,
  });
}

List<String> _parseCsv(String input) {
  return input
      .split(',')
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
}

int _positiveInt(String input, String optionName) {
  final value = int.tryParse(input);
  if (value == null || value <= 0) {
    throw FormatException('--$optionName must be a positive integer.');
  }
  return value;
}

int _median(List<int> sortedValues) {
  if (sortedValues.isEmpty) return 0;
  final middle = sortedValues.length ~/ 2;
  if (sortedValues.length.isOdd) return sortedValues[middle];
  return ((sortedValues[middle - 1] + sortedValues[middle]) / 2).round();
}

String _tail(String text, {int maxChars = 2000}) {
  if (text.length <= maxChars) return text.trim();
  return text.substring(math.max(0, text.length - maxChars)).trim();
}

String _defaultOutputPath() {
  final timestamp = DateTime.now()
      .toUtc()
      .toIso8601String()
      .replaceAll(':', '')
      .replaceAll('.', '');
  return p.join('benchmark', 'results', 'scan_benchmark_$timestamp.json');
}

String _targetName(String targetPath) {
  final absolutePath = p.absolute(targetPath);
  final sanitized = absolutePath
      .replaceAll(RegExp(r'^/+'), '')
      .replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '_');
  return sanitized.isEmpty ? 'root' : sanitized;
}

Directory _createScratchDir(String scratchRoot, String label) {
  final root = Directory(scratchRoot)..createSync(recursive: true);
  return root.createTempSync('${label}_');
}

String get _nullDevice => Platform.isWindows ? 'NUL' : '/dev/null';

void _printRun(
  String profile,
  String label,
  int iteration,
  int elapsedMs,
  int exitCode,
) {
  final status = exitCode == 0 ? 'ok' : 'exit $exitCode';
  stdout.writeln('  [$profile #$iteration] $label: ${elapsedMs}ms ($status)');
}
