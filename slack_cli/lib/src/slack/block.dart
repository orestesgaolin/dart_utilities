// ignore: one_member_abstracts
abstract class Block {
  Map<String, dynamic> toJson();
}

/// Holds multiple interactive elements.
class ActionsBlock extends Block {
  ActionsBlock({required this.elements});

  /// An array of interactive element objects - buttons, select menus, overflow menus, or date pickers.
  /// There is a maximum of 25 elements in each action block.
  final List<Map<String, dynamic>> elements;

  @override
  Map<String, dynamic> toJson() => {'type': 'actions', 'elements': elements};
}

/// Displays contextual info, which can include both images and text.
class ContextBlock extends Block {
  ContextBlock({required this.elements});

  /// An array of image elements and text objects.
  /// Maximum number of items is 10.
  final List<Map<String, dynamic>> elements;

  @override
  Map<String, dynamic> toJson() => {'type': 'context', 'elements': elements};
}

/// Visually separates pieces of info inside of a message.
class DividerBlock extends Block {
  @override
  Map<String, dynamic> toJson() => {'type': 'divider'};
}

/// Displays a remote file.
/// You can't add this block to app surfaces directly, but it will show up when retrieving messages that contain remote files.
class FileBlock extends Block {
  FileBlock({required this.externalId});

  /// The external unique ID for this file.
  final String externalId;

  @override
  Map<String, dynamic> toJson() =>
      {'type': 'file', 'external_id': externalId, 'source': 'remote'};
}

/// Displays a larger-sized text block.
/// Use it to delineate between different groups of content in your app's surfaces.
class HeaderBlock extends Block {
  HeaderBlock({required this.text});

  /// The text for the block.
  /// Maximum length for this field is 150 characters.
  final String text;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'header',
        'text': {'type': 'plain_text', 'text': text},
      };
}

/// Displays an image.
/// An image block, designed to make those cat photos really pop.
class ImageBlock extends Block {
  ImageBlock({required this.imageUrl, required this.altText, this.title});

  /// The URL of the image to be displayed.
  /// Maximum length for this field is 3000 characters.
  final String imageUrl;

  /// A plain-text summary of the image.
  /// Maximum length for this field is 2000 characters.
  final String altText;

  /// An optional title for the image.
  /// Maximum length for this field is 2000 characters.
  final String? title;

  @override
  Map<String, dynamic> toJson() {
    final block = <String, dynamic>{'type': 'image'};
    block['image_url'] = imageUrl;
    block['alt_text'] = altText;
    if (title != null) block['title'] = {'type': 'plain_text', 'text': title};

    return block;
  }
}

/// Collects information from users via block elements.
class InputBlock extends Block {
  InputBlock({required this.label, required this.element, this.hint});

  /// A label that appears above an input element.
  /// Maximum length for this field is 2000 characters.
  final String label;

  /// A plain-text input element, a checkbox element, a radio button element, a select menu element, a multi-select menu element, or a datepicker.
  final Map<String, dynamic> element;

  /// An optional hint that appears below an input element in a lighter grey.
  /// Maximum length for this field is 2000 characters.
  final String? hint;

  @override
  Map<String, dynamic> toJson() {
    final block = <String, dynamic>{'type': 'input'};
    block['label'] = {'type': 'plain_text', 'text': label};
    block['element'] = element;
    if (hint != null) block['hint'] = {'type': 'plain_text', 'text': hint};

    return block;
  }
}

/// Displays formated, structured representation of text.
class RichTextBlock extends Block {
  RichTextBlock({required this.elements});

  /// An array of rich text objects - rich_text_section, rich_text_list, rich_text_quote, rich_text_preformatted.
  final List<Map<String, dynamic>> elements;

  @override
  Map<String, dynamic> toJson() => {'type': 'rich_text', 'elements': elements};
}

/// Displays text, possibly alongside block elements.
/// A `section` can be used as a text block, in combination with text fields, or side-by-side with certain block elements.
class SectionBlock extends Block {
  SectionBlock({this.text, this.fields, this.accessory});

  /// The text for the block.
  /// Maximum length for this field is 3000 characters.
  /// This field is not required if a valid array of `fields` is provided instead.
  final String? text;

  /// Required if no `text` is provided.
  /// Any text included with `fields` will be rendered in a compact format that allows for 2 columns of side-by-side text.
  /// Maximum number of items is 10.
  /// Maximum length for each item is 2000 characters.
  final List<String>? fields;

  /// One of the compatible element objects.
  final Map<String, dynamic>? accessory;

  @override
  Map<String, dynamic> toJson() {
    final block = <String, dynamic>{'type': 'section'};
    if (text != null) block['text'] = {'type': 'mrkdwn', 'text': text};
    if (fields != null) {
      block['fields'] =
          fields!.map((f) => {'type': 'mrkdwn', 'text': f}).toList();
    }
    if (accessory != null) block['accessory'] = accessory;

    return block;
  }
}

/// Displays an embedded video player.
/// A `video` block is designed to embed videos in all app surfaces (e.g. link unfurls, messages, modals, App Home) - anywhere you can put blocks.
class VideoBlock extends Block {
  VideoBlock({
    required this.title,
    required this.thumbnailUrl,
    required this.videoUrl,
    this.altText,
    this.authorName,
    this.description,
    this.providerIconUrl,
    this.providerName,
    this.titleUrl,
  });

  /// A tooltip for the video.
  final String? altText;

  /// Author name to be displayed.
  /// Must be less than 50 characters.
  final String? authorName;

  /// Description for video in plain text format.
  /// Must be less than 200 characters.
  final String? description;

  /// Icon for the video provider.
  final String? providerIconUrl;

  /// The originating application or domain of the video.
  final String? providerName;

  /// Video title in plain text format.
  /// Must be less than 200 characters.
  final String title;

  /// Hyperlink for the title text.
  /// Must correspond to the non-embeddable HTTPS URL for the video.
  final String? titleUrl;

  /// The thumbnail image URL.
  final String thumbnailUrl;

  /// The URL to be embedded.
  /// Must match any existing unfurl domains within the app and point to a HTTPS URL.
  final String videoUrl;

  @override
  Map<String, dynamic> toJson() {
    final block = <String, dynamic>{'type': 'video'};
    block['alt_text'] = altText ?? title;
    if (authorName != null) block['author_name'] = authorName;
    if (description != null) {
      block['description'] = {'type': 'plain_text', 'text': description};
    }
    if (providerIconUrl != null) block['provider_icon_url'] = providerIconUrl;
    if (providerName != null) block['provider_name'] = providerName;
    block['title'] = {'type': 'plain_text', 'text': title};
    if (titleUrl != null) block['title_url'] = titleUrl;
    block['thumbnail_url'] = thumbnailUrl;
    block['video_url'] = videoUrl;

    return block;
  }
}
