import 'dart:convert';

import 'package:flutter/cupertino.dart';

/// An object which can be embedded into a Quill document.
///
/// See also:
///
/// * [BlockEmbed] which represents a block embed.
class Embeddable {
  const Embeddable(this.type, this.data);

  /// The type of this object.
  final String type;

  /// The data payload of this object.
  final dynamic data;

  Map<String, dynamic> toJson() {
    return {type: data};
  }

  static Embeddable fromJson(Map<String, dynamic> json) {
    final m = Map<String, dynamic>.from(json);
    assert(m.length == 1, 'Embeddable map must only have one key');

    return Embeddable(m.keys.first, m.values.first);
  }

  // Refer to https://www.fileformat.info/info/unicode/char/fffc/index.htm
  static const kObjectReplacementCharacter = '\uFFFC';

  String get toDetailPlantText {
    switch (type) {
      case BlockEmbed.imageType:
      case BlockEmbed.videoType:
      case BlockEmbed.linkPreviewType:
        return kObjectReplacementCharacter;

      case InlineBlockEmbed.hashtagType:
        return data;

      case InlineBlockEmbed.hyperlinkType:
        return _fetchUrl(data);

      default:
        return data;
    }
  }

  String _fetchUrl(String data) {
    try {
      final Map<String, dynamic> jsonData = jsonDecode(data);
      var link = '';
      jsonData.forEach((key, value) {
        link = value;
      });
      return link;
    } catch (e) {
      debugPrint('[[ Embeddable._fetchUrl ]]: error:$e');
      return '';
    }
  }
}

/// There are two built-in embed types supported by Quill documents, however
/// the document model itself does not make any assumptions about the types
/// of embedded objects and allows users to define their own types.
class BlockEmbed extends Embeddable {
  const BlockEmbed(String type, String data) : super(type, data);

  static const String imageType = 'image';
  static BlockEmbed image(String imageUrl) => BlockEmbed(imageType, imageUrl);

  static const String videoType = 'video';
  static BlockEmbed video(String videoUrl) => BlockEmbed(videoType, videoUrl);

  static const String formulaType = 'formula';
  static BlockEmbed formula(String formula) => BlockEmbed(formulaType, formula);

  static const String customType = 'custom';
  static BlockEmbed custom(CustomBlockEmbed customBlock) =>
      BlockEmbed(customType, customBlock.toJsonString());

  static const String linkPreviewType = 'linkPreview';
  static BlockEmbed linkPreview(String linkUrl) =>
      BlockEmbed(linkPreviewType, linkUrl);
}

class CustomBlockEmbed extends BlockEmbed {
  const CustomBlockEmbed(String type, String data) : super(type, data);

  String toJsonString() => jsonEncode(toJson());

  static CustomBlockEmbed fromJsonString(String data) {
    final embeddable = Embeddable.fromJson(jsonDecode(data));
    return CustomBlockEmbed(embeddable.type, embeddable.data);
  }
}

class InlineBlockEmbed extends Embeddable {
  InlineBlockEmbed(String type, String data) : super(type, data);

  static const String hashtagType = 'hashtag';
  static InlineBlockEmbed hashTag(String content) =>
      InlineBlockEmbed(hashtagType, content);

  static const String hyperlinkType = 'hyperlink';
  static InlineBlockEmbed hyperlink(String content) =>
      InlineBlockEmbed(hyperlinkType, content);
}
