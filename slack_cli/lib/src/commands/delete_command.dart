import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:http/http.dart' as http;
import 'package:mason_logger/mason_logger.dart';

class DeleteCommand extends Command<int> {
  DeleteCommand({
    required Logger logger,
  }) : _logger = logger {
    argParser
      ..addOption(
        'token',
        abbr: 't',
        help: 'API bot token used for authorization. See more ',
        mandatory: true,
      )
      ..addOption(
        'channel',
        abbr: 'c',
        help:
            'Channel where the message is present, bot needs to be authorized to access it e.g. C1234567890',
        mandatory: true,
      )
      ..addOption(
        'ts',
        help: 'Timestamp of the message to be deleted e.g. 1405894322.002768',
        mandatory: true,
      );
  }

  @override
  String get description => 'A command to delete message from Slack channel';

  @override
  String get name => 'delete';

  final Logger _logger;

  @override
  Future<int> run() async {
    final token = argResults?['token'] as String;
    final channel = argResults?['channel'] as String;
    final ts = argResults?['ts'] as String;

    _logger.info(
      'Deleting message from channel $channel with timestamp $ts',
    );
    final url = Uri.parse('https://slack.com/api/chat.delete');
    final response = await http.post(
      url,
      encoding: utf8,
      headers: {
        'Authorization': 'Bearer $token',
      },
      body: {
        'channel': channel,
        'ts': ts,
      },
    );
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (body['ok'] == true) {
        _logger.info('Message deleted successfully');
      } else {
        _logger.err('Error deleting message: $body');
      }
    }
    return ExitCode.success.code;
  }
}
