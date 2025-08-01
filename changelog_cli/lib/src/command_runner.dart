// Copyright (c) 2022, Very Good Ventures, Dominik Roszkowski
// https://verygood.ventures
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:changelog_cli/src/commands/commands.dart';
import 'package:changelog_cli/src/version.dart';
import 'package:cli_completion/cli_completion.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pub_updater/pub_updater.dart';

const executableName = 'changelog_cli';
const packageName = 'changelog_cli';
const description = 'Command line to generate changelogs';

/// {@template changelog_cli_command_runner}
/// A [CommandRunner] for the CLI.
///
/// ```bash
/// $ changelog_cli --version
/// ```
/// {@endtemplate}
class ChangelogCliCommandRunner extends CompletionCommandRunner<int> {
  /// {@macro changelog_cli_command_runner}
  ChangelogCliCommandRunner({Logger? logger, PubUpdater? pubUpdater})
    : _logger = logger ?? Logger(),
      _pubUpdater = pubUpdater ?? PubUpdater(),
      super(executableName, description) {
    // Add root options and flags
    argParser
      ..addFlag(
        'version',
        abbr: 'v',
        negatable: false,
        help: 'Print the current version.',
      )
      ..addFlag(
        'verbose',
        help: 'Noisy logging, including all shell commands executed.',
      );

    // Add sub commands
    addCommand(UpdateCommand(logger: _logger, pubUpdater: _pubUpdater));
    addCommand(GenerateCommand(logger: _logger));
    addCommand(ConfigCommand(logger: _logger));
  }

  @override
  void printUsage() => _logger.info(usage);

  final Logger _logger;
  final PubUpdater _pubUpdater;

  @override
  Future<int> run(Iterable<String> args) async {
    try {
      final topLevelResults = parse(args);
      if (topLevelResults['verbose'] == true) {
        _logger.level = Level.verbose;
      }
      return await runCommand(topLevelResults) ?? ExitCode.success.code;
    } on FormatException catch (e, stackTrace) {
      // On format errors, show the commands error message, root usage and
      // exit with an error code
      _logger
        ..err(e.message)
        ..err('$stackTrace')
        ..info('')
        ..info(usage);
      return ExitCode.usage.code;
    } on UsageException catch (e) {
      // On usage errors, show the commands usage message and
      // exit with an error code
      _logger
        ..err(e.message)
        ..info('')
        ..info(e.usage);
      return ExitCode.usage.code;
    }
  }

  @override
  Future<int?> runCommand(ArgResults topLevelResults) async {
    // Fast track completion command
    if (topLevelResults.command?.name == 'completion') {
      await super.runCommand(topLevelResults);
      return ExitCode.success.code;
    }

    // Verbose logs
    _logger
      ..detail('Argument information:')
      ..detail('  Top level options:');
    for (final option in topLevelResults.options) {
      if (topLevelResults.wasParsed(option)) {
        _logger.detail('  - $option: ${topLevelResults[option]}');
      }
    }
    if (topLevelResults.command != null) {
      final commandResult = topLevelResults.command!;
      await trackUsage(commandResult.name ?? 'unknown');
      _logger
        ..detail('  Command: ${commandResult.name}')
        ..detail('    Command options:');
      for (final option in commandResult.options) {
        if (commandResult.wasParsed(option)) {
          _logger.detail('    - $option: ${commandResult[option]}');
        }
      }
    }

    // Run the command or show version
    final int? exitCode;
    if (topLevelResults['version'] == true) {
      _logger.info(packageVersion);
      exitCode = ExitCode.success.code;
    } else {
      exitCode = await super.runCommand(topLevelResults);
    }

    // Check for updates
    if (topLevelResults.command?.name != UpdateCommand.commandName) {
      await _checkForUpdates();
    }

    return exitCode;
  }

  /// Checks if the current version (set by the build runner on the
  /// version.dart file) is the most recent one. If not, show a prompt to the
  /// user.
  Future<void> _checkForUpdates() async {
    try {
      final latestVersion = await _pubUpdater.getLatestVersion(packageName);
      final isUpToDate = packageVersion == latestVersion;
      if (!isUpToDate) {
        _logger
          ..info('')
          ..info('''
${lightYellow.wrap('Update available!')} ${lightCyan.wrap(packageVersion)} \u2192 ${lightCyan.wrap(latestVersion)}
Run ${lightCyan.wrap('$executableName update')} to update''');
      }
    } catch (_) {
      _logger.err('Failed to check for updates');
    }
  }

  Future<void> trackUsage(String command) async {
    try {
      unawaited(
        Process.run('curl', [
          '-X',
          'POST',
          '-H',
          'Origin: http://changelog.roszkowski.dev',
          'https://counter.dev/track?id=f9f43cb9-3e5b-4e7b-9f93-b56739d9b1db&page=$command',
        ], runInShell: true),
      );
      unawaited(
        Process.run('curl', [
          '-X',
          'POST',
          '-H',
          'Origin: http://changelog.roszkowski.dev',
          'https://counter.dev/trackpage?id=f9f43cb9-3e5b-4e7b-9f93-b56739d9b1db&page=$command',
        ], runInShell: true),
      );
    } catch (_) {}
  }
}
