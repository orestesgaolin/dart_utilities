import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:http/http.dart' as http;
import 'package:mason_logger/mason_logger.dart';
import 'package:slack_cli/src/slack/slack.dart';

/// {@template sample_command}
///  Command to send message to Slack
/// {@endtemplate}
class PostCommand extends Command<int> {
  /// {@macro sample_command}
  PostCommand({
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
            'Channel to send message to, bot needs to be authorized to access it',
        mandatory: true,
      )
      ..addOption(
        'message',
        abbr: 'm',
        help:
            'Text message to send to the specified channel, markdown formatting supported. '
            'Message is not shown in the Slack message content, but displayed in the notification if blocks are provided.',
      )
      ..addOption(
        'blocks',
        abbr: 'b',
        help:
            'Blocks to send to the channel, each block has its own type and formatting. \nexample:\n--blocks '
            '[header=This is the header][text=This is random text][divider]\n'
            'Special characters used as delimiters: [ ] =\n'
            'Type of the block needs to be the first element in the brackets [type=]\n'
            'Supported block types:\n'
            '  [text=This is simple text with *markdown* support and <http://google.com|links> ]\n'
            '  [header=This is the header]\n'
            '  [divider]\n'
            '  [img=https://assets3.thrillist.com/v1/image/1682388/size/tl-horizontal_main.jpg title=required title]\n'
            '  [fields=Text fields _use_ *markdown*=and are separated with=equal sign]\n'
            '  [button=Text on the left side url=http://pub.dev title=Button title] - all properties required\n'
            '  [context=This is _tiny_ message shown below]',
      );
  }

  @override
  String get description => 'A command to send message to Slack channel';

  @override
  String get name => 'post';

  final Logger _logger;

  @override
  Future<int> run() async {
    final token = argResults?['token'] as String;
    final channel = argResults?['channel'] as String;
    final message = argResults?['message'] as String? ?? '';
    final blocks = argResults?['blocks'] as String? ?? '';

    final response = await postMessage(
      token,
      channel,
      message,
      blocks,
    );

    _logger.info(response);
    return ExitCode.success.code;
  }

  Future<String> postMessage(
    String token,
    String channel,
    String message,
    String blocks,
  ) async {
    final url = Uri.parse('https://slack.com/api/chat.postMessage');

    final parsedBlocks = parseBlocks(blocks, logger: _logger);
    final response = await http.post(
      url,
      headers: {
        'Authorization': 'Bearer $token',
      },
      body: {
        'channel': channel,
        'text': message,
        'blocks': jsonEncode(parsedBlocks),
      },
    );
    if (response.statusCode == 200) {
      return 'Message sent successfully';
    } else {
      return 'Error sending message: ${response.body}';
    }
  }
}

List<Block> parseBlocks(String block, {Logger? logger}) {
  if (block.isEmpty) {
    return [];
  }
  if (!block.startsWith('[') || !block.endsWith(']')) {
    logger?.warn('Invalid block format. Should start with [ and end with ]. '
        'Block: $block');
    return [];
  }
  //remove starting and ending [ ]
  final blocks = block.substring(1, block.length - 1).split('][');
  final sections = <Block>[];
  for (final block in blocks) {
    final parts = block.split('=');
    if (parts.isNotEmpty) {
      if (parts[0] == 'fields') {
        final fields = parts.sublist(1);
        sections.add(SectionBlock(fields: fields));
        continue;
      }
    }
    if (parts.length == 1) {
      final type = parts[0];
      switch (type) {
        case 'divider':
          sections.add(DividerBlock());
      }
      continue;
    }
    if (parts.length >= 2) {
      final type = parts[0];
      final text = parts[1];
      switch (type) {
        case 'header':
          sections.add(HeaderBlock(text: text));
        case 'text':
          final formattedText = text.replaceAll(r'\n', '\n');
          sections.add(
            SectionBlock(
              text: formattedText,
            ),
          );
        case 'img':
          final image = parseImageText(block);
          sections.add(
            ImageBlock(
              imageUrl: image.url,
              title: image.altText,
              altText: image.altText,
            ),
          );

        case 'button':
          final button = parseButtonText(block);
          sections.add(
            SectionBlock(
              text: button.button,
              accessory: {
                'type': 'button',
                'text': {
                  'type': 'plain_text',
                  'text': button.title,
                  'emoji': true,
                },
                'url': button.url,
              },
            ),
          );
        case 'context':
          sections.add(
            ContextBlock(
              elements: [
                {
                  'type': 'mrkdwn',
                  'text': text,
                }
              ],
            ),
          );
      }
    }
  }
  return sections;
}

({String url, String altText}) parseImageText(String input) {
  final imgRegex = RegExp(r'img=([^\s]+)'); // Match img URL
  final titleRegex = RegExp('title=([^[]+)'); // Match title text

  final url = imgRegex.firstMatch(input)?.group(1);
  final altText = titleRegex.firstMatch(input)?.group(1);

  return (url: url?.trim() ?? '', altText: altText?.trim() ?? '');
}

({String button, String url, String title}) parseButtonText(String input) {
  final buttonRegex = RegExp(r'button=(.*?)\s+(?=url=|title=|$)');
  final urlRegex = RegExp(r'url=(.*?)(?=\s+title=|button=|$)');
  final titleRegex = RegExp(r'title=(.*?)(?=\s+url=|button=|$)');

  final buttonMatch = buttonRegex.firstMatch(input);
  final urlMatch = urlRegex.firstMatch(input);
  final titleMatch = titleRegex.firstMatch(input);

  final button = buttonMatch?.group(1);
  final url = urlMatch?.group(1);
  final title = titleMatch?.group(1);

  return (
    button: button?.trim() ?? '',
    url: url?.trim() ?? '',
    title: title?.trim() ?? ''
  );
}
