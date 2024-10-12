// ignore_for_file: missing_whitespace_between_adjacent_strings, no_adjacent_strings_in_list

import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:slack_cli/src/command_runner.dart';
import 'package:slack_cli/src/commands/post_command.dart';
import 'package:slack_cli/src/slack/slack.dart';
import 'package:test/test.dart';

class _MockLogger extends Mock implements Logger {}

void main() {
  group('sample', () {
    late Logger logger;
    late SlackCliCommandRunner commandRunner;

    setUp(() {
      logger = _MockLogger();
      commandRunner = SlackCliCommandRunner(logger: logger);
    });

    test('sends a message to a specified channel', () async {
      const token = '';

      assert(token.isNotEmpty, "Token can't be empty");
      final exitCode = await commandRunner.run(
        [
          'post',
          '--token',
          token,
          '--channel',
          'test-channel',
          '--message',
          'Sample message from test',
          '--blocks',
          '[header=This is the header]'
              '[fields=Text fields _use_ *markdown*=and are <https://google.com|separated> with=equal sign]'
              '[button=Text on the left side url=http://pub.dev title=Button title]'
              '[context=This is _tiny_ message shown below]',
        ],
      );

      expect(exitCode, ExitCode.success.code);
    });
  });

  group('parseBlocks', () {
    test('can parse basic blocks', () async {
      const testString = '[header=This is the header]'
          '[text=This is random text with :wave: emoji and *markdown* _basic_ support.\nThis is new line]'
          '[divider]'
          '[img=https://assets3.thrillist.com/v1/image/1682388/size/tl-horizontal_main.jpg title=this is image]'
          '[img=https://assets3.thrillist.com/v1/image/1682388/size/tl-horizontal_main.jpg ]'
          r'[text=This is\nnew line]'
          '[fields=Text fields _use_ *markdown*=and are separated with=equal sign]';

      final blocks = parseBlocks(testString);
      expect(blocks.length, 7);
      expect(blocks[0], isA<HeaderBlock>());
      expect(blocks[1], isA<SectionBlock>());
      expect(blocks[2], isA<DividerBlock>());
      expect(blocks[3], isA<ImageBlock>());
      expect(blocks[4], isA<ImageBlock>());
      expect(blocks[5], isA<SectionBlock>());
      expect(blocks[6], isA<SectionBlock>());
    });
  });

  group('parseImageText', () {
    test('can parse image text', () async {
      const testString =
          'img=https://assets3.thrillist.com/v1/image/1682388/size/tl-horizontal_main.jpg title=this is image';

      final image = parseImageText(testString);
      expect(image.altText, 'this is image');
      expect(image.url,
          'https://assets3.thrillist.com/v1/image/1682388/size/tl-horizontal_main.jpg');
    });
  });

  group('parseButtonText', () {
    test('can parse button text', () async {
      const testString =
          'button=Text on the left side url=https://google.com title=Button title';

      final button = parseButtonText(testString);
      expect(button.button, 'Text on the left side');
      expect(button.url, 'https://google.com');
      expect(button.title, 'Button title');
    });

    test('can parse button text with different order', () async {
      const testString =
          'button=Text on the left side title=Button title url=https://google.com';

      final button = parseButtonText(testString);
      expect(button.button, 'Text on the left side');
      expect(button.url, 'https://google.com');
      expect(button.title, 'Button title');
    });
  });
}
