// ignore_for_file: cascade_invocations, use_if_null_to_convert_nulls_to_bools

import 'package:args/command_runner.dart';
import 'package:changelog_cli/src/model/model.dart';
import 'package:changelog_cli/src/printers/printers.dart';
import 'package:changelog_cli/src/processors/processors.dart';
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
      help: 'Start git reference (e.g. commit SHA or tag)',
    );
    argParser.addOption(
      'end',
      abbr: 'e',
      help: 'End git reference (e.g. commit SHA or tag)',
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
      help: 'Path to the git repository or folder in that repository. '
          'Providing a subdirectory will limit the changelog to '
          'that subdirectory.',
      defaultsTo: '.',
    );
    argParser.addOption(
      'version',
      abbr: 'v',
      help: 'Manually specify version printed in the header of the changelog',
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
      'auto-tag-glob-pattern',
      help: 'If [auto] is set to true, then you can pass pattern that will be '
          'used when detecting previous tag.\nFor instance if there is '
          'a monorepo with releases tagged with package_a-1.0.0 and '
          'library_b-2.0.0, then you can pass "package_a*" glob pattern, so '
          'that git describe will include only tags matching the pattern.',
    );
    argParser.addOption(
      'printer',
      abbr: 'P',
      help: 'Select output printer',
      defaultsTo: 'simple',
      allowed: [
        'simple',
        'markdown',
        'slack-markdown',
      ],
    );
    argParser.addOption(
      'group-by',
      abbr: 'g',
      help: 'Group entries by type',
      allowed: [
        'date-asc',
        'date-desc',
        'scope-asc',
        'scope-desc',
      ],
    );
    argParser.addOption(
      'date-format',
      help: 'Date format, providing empty skips date formatting. \nNeeds '
          'to be valid ISO date format e.g. yyyy-MM-dd, yyyy-MM-dd HH:mm:ss. '
          'By default it does not print any dates. Uses system-default locale.',
      defaultsTo: '',
    );
    argParser.addOption(
      'date-format-locale',
      help: 'Date format passed to the date formatting, expected format: xx_XX',
      defaultsTo: 'en_US',
    );
    argParser.addOption(
      'jira-url',
      help: 'When provided, the command will try to detect issue numbers e.g. '
          'AB-123 or CD-1234 and some printers will add links to the issues.',
      defaultsTo: '',
      valueHelp: 'https://companyname.atlassian.net/browse/',
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
    if (argResults == null) {
      return ExitCode.usage.code;
    }

    final configuration = GenerateConfiguration.fromArgs(argResults!);

    final path = await getGitPath();

    if (path != null) {
      final String? startRef;
      if (configuration.auto) {
        startRef = await getLastTag(
            path: path, pattern: configuration.autoGlobPattern);
      } else {
        startRef = configuration.start;
      }

      final commits = await getCommits(
        start: startRef,
        end: configuration.end,
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
          if (configuration.include.contains(conventionalCommit.type)) {
            list.add(
              ChangelogEntry(
                conventionalCommit: conventionalCommit,
                ref: v.key,
                commit: v.value,
                date: parseDate(v.value.author),
              ),
            );
          }
        }
      }
      _logger.detail('Found ${list.length} conventional commits');

      final processedList = Preprocessor.processGitHistory(list, configuration);

      final printer = getPrinter(configuration);

      final output = printer.print(entries: processedList);

      if (configuration.limit > 0) {
        final limitClamped = configuration.limit.clamp(0, output.length);
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
          ['rev-list', '--format=raw', endRef, '^$start', path],
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
    required String pattern,
  }) async {
    try {
      final gitDir = await GitDir.fromExisting(path, allowSubdirectory: true);

      final commitsRaw = await gitDir.runCommand([
        'describe',
        '--tags',
        '--abbrev=0',
        if (pattern.isNotEmpty) '--match=$pattern',
      ]);

      final tag = (commitsRaw.stdout as String).replaceAll('\n', '');
      return tag;
    } catch (e) {
      _logger.warn('Could not get tag: $e');
      return null;
    }
  }

  Printer getPrinter(GenerateConfiguration configuration) {
    switch (configuration.printer) {
      case PrinterType.markdown:
        return MarkdownPrinter(configuration: configuration);
      case PrinterType.slackMarkdown:
        return SlackMarkdownPrinter(configuration: configuration);
      case PrinterType.simple:
        return SimplePrinter(configuration: configuration);
    }
  }
}

DateTime? parseDate(String gitAuthor) {
  final author = gitAuthor.split(' ');
  final oneBeforeLast = author.length - 2;
  final date = author[oneBeforeLast];
  final seconds = int.tryParse(date);
  if (seconds != null) {
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  }
  return null;
}
