import 'dart:convert';
import 'dart:math' as math;

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
            '  [button=Button title url=http://pub.dev] - all properties required\n'
            '  [button_section=Text on the left side url=http://pub.dev title=Button title] - all properties required\n'
            '  [context=This is _tiny_ message shown below]',
      )
      ..addFlag(
        'unfurl-media',
        help: 'Flag passed to the Slack message body to enable media unfurling',
        // ignore: avoid_redundant_argument_values
        defaultsTo: false,
      )
      ..addFlag(
        'unfurl-links',
        help: 'Flag passed to the Slack message body to enable links unfurling',
        // ignore: avoid_redundant_argument_values
        defaultsTo: false,
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

    final responses = await postMessage(
      token,
      channel,
      message,
      blocks,
      unfurlMedia: argResults?['unfurl-media'] == true,
      unfurlLinks: argResults?['unfurl-links'] == true,
    );

    for (final response in responses) {
      _logger.info(
        response.success
            ? 'Message sent successfully to channel ${response.channel} with timestamp ${response.ts}'
            : 'Error sending message: ${response.error}',
      );
    }
    return responses.any((e) => !e.success)
        ? ExitCode.software.code
        : ExitCode.success.code;
  }

  Future<List<PostCommandResponse>> postMessage(
    String token,
    String channel,
    String message,
    String blocks, {
    required bool unfurlMedia,
    required bool unfurlLinks,
  }) async {
    final url = Uri.parse('https://slack.com/api/chat.postMessage');

    final parsedBlocks = parseBlocks(blocks, logger: _logger);

    // need to split into multiple messages of up to 50 blocks
    final numberOfMessages = (parsedBlocks.length / 50).ceil();

    final responses = <PostCommandResponse>[];
    for (var messageIndex = 0;
        messageIndex < numberOfMessages;
        messageIndex++) {
      final blocksSublist = parsedBlocks.sublist(
        messageIndex * 50,
        math.min((messageIndex + 1) * 50, parsedBlocks.length),
      );
      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer $token',
        },
        body: {
          'channel': channel,
          'text': message,
          'unfurl_media': unfurlMedia.toString(),
          'unfurl_links': unfurlLinks.toString(),
          'blocks': jsonEncode(blocksSublist),
        },
      );
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        if (body['ok'] == true) {
          _logger
            ..detail('Response: $body')
            ..info(
              'Message sent successfully (${messageIndex + 1}/$numberOfMessages)',
            );
          responses.add(
            PostCommandResponse(
              success: true,
              error: null,
              channel: body['channel'] as String,
              ts: body['ts'] as String,
            ),
          );
        } else {
          _logger.err('Error sending message: $body');
          responses.add(
            PostCommandResponse(
              success: false,
              error: body['error'] as String,
            ),
          );
        }
      } else {
        _logger.err('Error sending message: ${response.body}');
        responses.add(
          PostCommandResponse(
            success: false,
            error: response.body,
          ),
        );
      }
    }
    return responses;
  }
}

class PostCommandResponse {
  PostCommandResponse({
    required this.success,
    required this.error,
    this.channel,
    this.ts,
  });

  final bool success;
  final String? error;
  final String? channel;
  final String? ts;
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
          final parsedSections = parseText(text, logger);
          sections.addAll(parsedSections);
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
            ActionsBlock(
              elements: [
                {
                  'type': 'button',
                  'text': {
                    'type': 'plain_text',
                    'text': button.button,
                    'emoji': true,
                  },
                  'value': 'button',
                  'url': button.url,
                },
              ],
            ),
          );
        case 'button_section':
          final button = parseButtonSectionText(block);
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
                'value': 'button',
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

List<Block> parseText(String text, Logger? logger) {
  final sections = <Block>[];
  final formattedText = text.replaceAll(r'\n', '\n');
  if (formattedText.length > 2999) {
    logger?.detail(
      'Need to split block into segments of 3000 characters',
    );
    if (formattedText.length > 2999) {
      logger?.detail(
        'Splitting block into segments of 3000 characters at whitespace',
      );
      final chunks = <String>[];
      var currentPosition = 0;

      while (currentPosition < formattedText.length) {
        var endPosition =
            math.min(currentPosition + 2999, formattedText.length);

        if (endPosition < formattedText.length) {
          // Look for last whitespace within the 3000 char limit
          final lastWhitespace =
              formattedText.lastIndexOf(RegExp(r'\s'), endPosition);

          // If we found a whitespace and it's after our current position
          if (lastWhitespace > currentPosition) {
            endPosition =
                lastWhitespace + 1; // Include the whitespace in current chunk
          }
          // If no whitespace found, we'll have to split at 3000 chars
        }

        final chunk = formattedText.substring(currentPosition, endPosition);
        chunks.add(chunk);
        currentPosition = endPosition;
      }

      for (final chunk in chunks) {
        if (chunk.trim().isNotEmpty) {
          sections.add(
            SectionBlock(
              text: chunk,
            ),
          );
        }
      }
    }
  } else {
    if (formattedText.trim().isNotEmpty) {
      sections.add(
        SectionBlock(
          text: formattedText,
        ),
      );
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

({String button, String url, String title}) parseButtonSectionText(
  String input,
) {
  final buttonRegex = RegExp(r'button_section=(.*?)\s+(?=url=|title=|$)');
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

({String button, String url}) parseButtonText(
  String input,
) {
  final buttonRegex = RegExp(r'button=(.*?)\s+(?=url=|title=|$)');
  final urlRegex = RegExp(r'url=(.*?)(?=\s+title=|button=|$)');

  final buttonMatch = buttonRegex.firstMatch(input);
  final urlMatch = urlRegex.firstMatch(input);

  final button = buttonMatch?.group(1);
  final url = urlMatch?.group(1);

  return (
    button: button?.trim() ?? '',
    url: url?.trim() ?? '',
  );
}
