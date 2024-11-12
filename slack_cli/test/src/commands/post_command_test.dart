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
              '[button_section=Text on the left side url=http://pub.dev title=Button title]'
              '[button=Button text url=http://pub.dev]'
              '[text=Long text long text long text long text long text long text long text]'
              '[text=Long text long text long text long text long text long text long text]'
              '[text=End of message]'
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

    test(
      'splits texts longer than 3000 characters into multiple sections',
      () {
        final longText = 'word ' * 1000;
        final testString = '[text=$longText]';

        final blocks = parseBlocks(testString);

        // Should create multiple blocks since text > 3000 chars
        expect(blocks.length, greaterThan(1));
        expect(blocks.every((block) => block is SectionBlock), true);

        // Each block should be <= 3000 chars
        for (final block in blocks) {
          final sectionBlock = block as SectionBlock;
          expect(sectionBlock.text?.length, lessThanOrEqualTo(3000));
        }

        // No words should be split (no blocks should end with non-space character and start with non-space character)
        for (var i = 0; i < blocks.length - 1; i++) {
          final currentBlock = blocks[i] as SectionBlock;
          final nextBlock = blocks[i + 1] as SectionBlock;

          final currentEndsWithPartialWord = !currentBlock.text!.endsWith(' ');
          final nextStartsWithPartialWord = !nextBlock.text!.startsWith(' ');

          expect(
            currentEndsWithPartialWord && nextStartsWithPartialWord,
            false,
            reason: 'Text should not be split mid-word between blocks',
          );
        }

        // Combined text should equal original (after normalizing spaces)
        final combinedText = blocks
            .map((block) => (block as SectionBlock).text)
            .join(' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        final normalizedOriginal =
            longText.replaceAll(RegExp(r'\s+'), ' ').trim();
        expect(combinedText, normalizedOriginal);
      },
    );
  });

  group('parseImageText', () {
    test('can parse image text', () async {
      const testString =
          'img=https://assets3.thrillist.com/v1/image/1682388/size/tl-horizontal_main.jpg title=this is image';

      final image = parseImageText(testString);
      expect(image.altText, 'this is image');
      expect(
        image.url,
        'https://assets3.thrillist.com/v1/image/1682388/size/tl-horizontal_main.jpg',
      );
    });
  });

  group('parseButtonSectionText', () {
    test('can parse button_section elements', () async {
      const testString =
          'button_section=Text on the left side url=https://google.com title=Button title';

      final button = parseButtonSectionText(testString);
      expect(button.button, 'Text on the left side');
      expect(button.url, 'https://google.com');
      expect(button.title, 'Button title');
    });

    test('can parse button_section elements with different order', () async {
      const testString =
          'button_section=Text on the left side title=Button title url=https://google.com';

      final button = parseButtonSectionText(testString);
      expect(button.button, 'Text on the left side');
      expect(button.url, 'https://google.com');
      expect(button.title, 'Button title');
    });
  });

  group('parseButtonText', () {
    test('can parse button_section elements', () async {
      const testString = 'button=Button title url=https://google.com';

      final button = parseButtonText(testString);
      expect(button.button, 'Button title');
      expect(button.url, 'https://google.com');
    });
  });
}
