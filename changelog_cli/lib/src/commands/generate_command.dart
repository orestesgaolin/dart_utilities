// ignore_for_file: cascade_invocations, use_if_null_to_convert_nulls_to_bools

import 'package:args/command_runner.dart';
import 'package:changelog_cli/src/model/model.dart';
import 'package:changelog_cli/src/printers/printers.dart';
import 'package:conventional_commit/conventional_commit.dart';
import 'package:git/git.dart';
import 'package:mason_logger/mason_logger.dart';

/// {@template generate_command}
///
/// `changelog_cli generate`
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

    final path = argResults!['path'] as String;
    _logger.info('Reading git history from $path');

    if (await GitDir.isGitDir(path)) {
      final commits = await getCommits(
        start: start,
        end: end,
        path: path,
      );

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
      _logger.info('Found ${list.length} conventional commits');

      final output = SimplePrinter(include).print(list);
      _logger.info(output);
    } else {
      _logger.warn('Not a Git directory');
      return ExitCode.usage.code;
    }

    return ExitCode.success.code;
  }

  Future<Map<String, Commit>> getCommits({
    required String path,
    required String? start,
    required String? end,
  }) async {
    final gitDir = await GitDir.fromExisting(path);

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
  }
}
