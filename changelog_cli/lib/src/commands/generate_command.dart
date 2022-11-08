// ignore_for_file: cascade_invocations, use_if_null_to_convert_nulls_to_bools

import 'package:args/command_runner.dart';
import 'package:changelog_cli/src/model/model.dart';
import 'package:changelog_cli/src/printers/printers.dart';
import 'package:conventional_commit/conventional_commit.dart';
import 'package:git/git.dart';
import 'package:mason_logger/mason_logger.dart';

/// {@template generate_command}
/// `changelog_cli generate`
///
/// A [Command] to generate a changelog
/// {@endtemplate}
class GenerateCommand extends Command<int> {
  /// {@macro generate_command}
  GenerateCommand({
    required Logger logger,
  }) : _logger = logger {
    argParser.addOption(
      'start',
      abbr: 's',
      help: 'Start git reference (e.g. commit SHA)',
    );
    argParser.addOption(
      'end',
      abbr: 'e',
      help: 'End git reference (e.g. commit SHA)',
    );
    argParser.addMultiOption(
      'include',
      abbr: 'i',
      help: 'List of types of conventional commits to include. '
          'Order of types defines the order of sections.',
      defaultsTo: [
        'feat',
        'fix',
        'refactor',
        'perf',
      ],
    );
    argParser.addOption(
      'path',
      abbr: 'p',
      help: 'Path to the package',
      defaultsTo: '.',
    );
    argParser.addOption(
      'version',
      abbr: 'v',
      help: 'Manually specify version',
      defaultsTo: '',
    );
    argParser.addOption(
      'limit',
      abbr: 'l',
      help: 'Max length of the changelog '
          '(you can use e.g. 500 for AppStore changelog)',
      defaultsTo: '',
    );
    argParser.addFlag(
      'auto',
      abbr: 'a',
      help: 'Automatically detect previous tag by using git describe',
      // ignore: avoid_redundant_argument_values
      defaultsTo: false,
    );
    argParser.addOption(
      'printer',
      abbr: 'P',
      help: 'Select output printer',
      defaultsTo: 'simple',
      allowed: [
        'simple',
        'markdown',
      ],
    );
  }

  @override
  String get description => 'Generates the changelog using conventional '
      'commits and provided git references';

  @override
  String get name => 'generate';

  final Logger _logger;

  @override
  Future<int> run() async {
    final start = argResults?['start'] as String?;
    final end = argResults?['end'] as String?;
    final include = argResults?['include'] as List<String>? ?? [];
    final version = argResults?['version'] as String;
    final limit = int.tryParse(argResults?['limit'] as String? ?? '');

    final path = await getGitPath();

    if (path != null) {
      final String? startRef;
      if (argResults?['auto'] == true) {
        startRef = await getLastTag(path: path);
      } else {
        startRef = start;
      }

      final commits = await getCommits(
        start: startRef,
        end: end,
        path: path,
      );
      if (commits.isEmpty) {
        _logger.info('No changes found');
        return ExitCode.success.code;
      }

      final list = <ChangelogEntry>[];
      for (final v in commits.entries) {
        final conventionalCommit = ConventionalCommit.tryParse(v.value.message);

        if (conventionalCommit != null) {
          if (include.contains(conventionalCommit.type)) {
            list.add(
              ChangelogEntry(
                conventionalCommit: conventionalCommit,
                ref: v.key,
                commit: v.value,
              ),
            );
          }
        }
      }
      _logger.detail('Found ${list.length} conventional commits');

      final printer = getPrinter(argResults?['printer'] as String?);

      final output = printer.print(
        entries: list,
        version: version,
        types: include,
      );

      if (limit != null && limit > 0) {
        final limitClamped = limit.clamp(0, output.length);
        _logger.info(output.substring(0, limitClamped));
      } else {
        _logger.info(output);
      }
    } else {
      _logger.warn('Not a Git directory');
      return ExitCode.usage.code;
    }

    return ExitCode.success.code;
  }

  Future<String?> getGitPath() async {
    final argPath = argResults!['path'] as String;
    _logger.detail('Reading git history from $argPath');

    final isGit = await GitDir.isGitDir(argPath);
    _logger.detail('Repository is git root: $isGit');
    if (isGit) {
      return argPath;
    }
    return null;
  }

  Future<Map<String, Commit>> getCommits({
    required String path,
    required String? start,
    required String? end,
  }) async {
    try {
      final gitDir = await GitDir.fromExisting(path, allowSubdirectory: true);

      if (start?.isNotEmpty == true) {
        final endRef = end?.isNotEmpty == true ? end! : 'HEAD';
        final commitsRaw = await gitDir.runCommand(
          ['rev-list', '--format=raw', endRef, '^$start'],
        );
        final commits = Commit.parseRawRevList(commitsRaw.stdout as String);
        return commits;
      } else {
        final commits = await gitDir.commits();
        return commits;
      }
    } catch (e) {
      _logger.warn('Could not get commits for specified range: $e');
      return {};
    }
  }

  Future<String?> getLastTag({
    required String path,
  }) async {
    try {
      final gitDir = await GitDir.fromExisting(path, allowSubdirectory: true);

      final commitsRaw = await gitDir.runCommand([
        'describe',
        '--tags',
        '--abbrev=0',
      ]);

      final tag = (commitsRaw.stdout as String).replaceAll('\n', '');
      return tag;
    } catch (e) {
      _logger.warn('Could not get tag: $e');
      return null;
    }
  }

  Printer getPrinter(String? argResult) {
    switch (argResult) {
      case 'markdown':
        return MarkdownPrinter();
      default:
        return SimplePrinter();
    }
  }
}
