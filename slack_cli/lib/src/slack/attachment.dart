class Attachment {
  Attachment({
    this.authorIcon,
    this.authorLink,
    this.authorName,
    this.color,
    this.fallback,
    this.fields,
    this.footer,
    this.footerIcon,
    this.imageUrl,
    this.pretext,
    this.text,
    this.thumbUrl,
    this.title,
    this.titleLink,
    this.ts,
  });

  /// A valid URL that displays a small 16px by 16px image to the left of the `authorName` text.
  /// Will only work if `authorName` is present.
  final String? authorIcon;

  /// A valid URL that will hyperlink the `authorName` text.
  /// Will only work if `authorName` is present.
  final String? authorLink;

  /// Small text used to display the author's name.
  final String? authorName;

  /// Changes the color of the border on the left side of this attachment from the default gray.
  /// Can either be one of `good` (green), `warning` (yellow), `danger` (red), or any hex color code (eg. `#439FE0`).
  final String? color;

  /// A plain text summary of the attachment used in clients that don't show formatted text (eg. IRC, mobile notifications).
  final String? fallback;

  /// An array of field objects that get displayed in a table-like way.
  /// For best results, include no more than 2-3 field objects.
  final List<Field>? fields;

  /// Some brief text to help contextualize and identify an attachment.
  /// Limited to 300 characters, and may be truncated further when displayed to users in environments with limited screen real estate.
  final String? footer;

  /// A valid URL to an image file that will be displayed beside the `footer` text.
  /// Will only work if `authorName` is present.
  /// We'll render what you provide at 16px by 16px.
  /// It's best to use an image that is similarly sized.
  final String? footerIcon;

  /// A valid URL to an image file that will be displayed at the bottom of the attachment.
  /// We support GIF, JPEG, PNG, and BMP formats.
  ///
  /// Large images will be resized to a maximum width of 360px or a maximum height of 500px, while still maintaining the original aspect ratio.
  /// Cannot be used with `thumbUrl`.
  final String? imageUrl;

  /// Text that appears above the message attachment block.
  final String? pretext;

  /// The main body text of the attachment.
  /// The content will automatically collapse if it contains 700+ characters or 5+ linebreaks, and will display a "Show more..." link to expand the content.
  final String? text;

  /// A valid URL to an image file that will be displayed as a thumbnail on the right side of a message attachment.
  /// We currently support the following formats: GIF, JPEG, PNG, and BMP.
  ///
  /// The thumbnail's longest dimension will be scaled down to 75px while maintaining the aspect ratio of the image.
  /// The filesize of the image must also be less than 500 KB.
  ///
  /// For best results, please use images that are already 75px by 75px.
  final String? thumbUrl;

  /// Large title text near the top of the attachment.
  final String? title;

  /// A valid URL that turns the `title` text into a hyperlink.
  final String? titleLink;

  /// An integer Unix timestamp that is used to related your attachment to a specific time.
  /// The attachment will display the additional timestamp value as part of the attachment's footer.
  ///
  /// Your message's timestamp will be displayed in varying ways, depending on how far in the past or future it is, relative to the present.
  /// Form factors, like mobile versus desktop may also transform its rendered appearance.
  final int? ts;

  Map<String, dynamic> toJson() {
    final attachment = <String, dynamic>{};
    if (authorIcon != null) attachment['author_icon'] = authorIcon;
    if (authorLink != null) attachment['author_link'] = authorLink;
    if (authorName != null) attachment['author_name'] = authorName;
    if (color != null) attachment['color'] = color;
    if (fallback != null) attachment['fallback'] = fallback;
    if (fields != null) attachment['fields'] = fields;
    if (footer != null) attachment['footer'] = footer;
    if (footerIcon != null) attachment['footer_icon'] = footerIcon;
    if (imageUrl != null) attachment['image_url'] = imageUrl;
    if (pretext != null) attachment['pretext'] = pretext;
    if (text != null) attachment['text'] = text;
    if (thumbUrl != null) attachment['thumb_url'] = thumbUrl;
    if (title != null) attachment['title'] = title;
    if (titleLink != null) attachment['title_link'] = titleLink;
    if (ts != null) attachment['ts'] = ts;

    return attachment;
  }
}

class Field {
  Field({this.title, this.value, this.short});

  /// Shown as a bold heading displayed in the field object.
  final String? title;

  /// The text value displayed in the field object.
  final String? value;

  /// Indicates whether the field object is short enough to be displayed side-by-side with other field objects.
  /// Defaults to `false`.
  final bool? short;

  Map<String, dynamic> toJson() {
    final field = <String, dynamic>{};
    if (title != null) field['title'] = title;
    if (value != null) field['value'] = value;
    if (short != null) field['short'] = short;

    return field;
  }
}
