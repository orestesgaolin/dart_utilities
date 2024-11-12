## slack_cli

Simple CLI to call Slack API and send messages.

```sh
slack_cli post -t xoxb-xxx \
  -c channel-name \
  -m "Hello world"
```

Supported commands:

- `post` - sends a message to Slack channel ([API method](https://api.slack.com/methods/chat.postMessage))
- `delete` - deletes a message from Slack channel by timestamp ([API method](https://api.slack.com/methods/chat.delete))
- `update` - updates the CLI

## Installation

### Pub.dev

Activate globally from pub.dev via:

```sh
dart pub global activate slack_cli
```

Or locally via:

```sh
dart pub global activate --source=path <path to this package>
```

### Homebrew

You can install the CLI via Homebrew:

```sh
brew tap orestesgaolin/tap
brew install slack_cli
```

## Usage

Make sure to grant your application the necessary permissions to send messages to Slack channels. See [this official manual](https://api.slack.com/scopes) for more details, but in general you may want to grant: `channels:history`, `channels:read`, `chat:write`, `chat:write.customize`, `chat:write.public`, `groups:history`, `groups:read`.

### Posting messages

The `post` command allows to send messages to desired Slack channel. Before you use this CLI, you need to create Slack app and get bot token. See [this official manual](https://api.slack.com/quickstart) for more details. Once you have the token (it starts with `xoxb-`), you can use it to send messages to Slack channels.

```sh
slack_cli post --token <token> --channel <channel> --message <message> --blocks <blocks>
```

This command returns the channel and timestamp of the message sent to Slack channel if successful. This can be later used to delete the message. If there are more than 50 blocks, the command will split the message into multiple messages. If the message in the text block is longer than 3000 characters, it will be split into multiple text sections of up to 3000 characters.

```sh
slack_cli post -t xoxb-xxx \
-c builds \
-m "Build 1234 finished" \
-b "[header=App build 1234 :white_check_mark:][fields=Commit \`93f5a0f\`=Branch \`main\`=Workflow \`production\`][text=*Changelog*\n - *General*: Audio of objects falling at night increased by 33% <https://pub.dev|EU-2137>\n - *Sounds*: All instruments have been replaced with Chipi Chipi Chapa Chapa <https://pub.dev|EU-997>][divider][text=*Artifacts*][button_section=Download all artifacts url=http://pub.dev title=Download][button=Android APK (60 MB) url=http://pub.dev][button=iOS IPA (100 MB) url=http://pub.dev][context=Build run on Oct 10, 2024]"

Message sent successfully to channel C1234567890 with timestamp 1405894322.002768
```

![](example/screenshots/slack_cli_output.png)

### Deleting messages

The `delete` command deletes the message sent to Slack channel by timestamp. You can get the timestamp of the message by running the `post` command and checking the output.

```sh
slack_cli delete -t xoxb-xxx \
-c C1234567890 \
--ts 1405894322.002768
```

### Supported blocks

Blocks to send to the channel, each block has its own type and formatting.

Special characters used as delimiters: `[ ] =`

```
[text=This is simple text with *markdown* support and <http://google.com|links>]
[header=This is the header]
[divider]
[img=https://assets3.thrillist.com/v1/image/1682388/size/tl-horizontal_main.jpg title=required title]
[fields=Text fields _use_ *markdown*=and are separated with=equal sign]
[button=Button label url=http://pub.dev]
[button_section=Text on the left side url=http://pub.dev title=Button title] - all properties required
[context=This is _tiny_ message shown below]',
```

## Special thanks

This project uses block classes from [slack_notifier](https://pub.dev/packages/slack_notifier).
