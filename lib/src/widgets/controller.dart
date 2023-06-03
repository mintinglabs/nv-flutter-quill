import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:tuple/tuple.dart';

import '../models/documents/attribute.dart';
import '../models/documents/document.dart';
import '../models/documents/nodes/embeddable.dart';
import '../models/documents/nodes/leaf.dart';
import '../models/documents/style.dart';
import '../models/quill_delta.dart';
import '../utils/delta.dart';

typedef ReplaceTextCallback = bool Function(int index, int len, Object? data);
typedef DeleteCallback = void Function(int cursorPosition, bool forward);

typedef HashtagCallback = Future<void> Function(
    int index, int len, String data);

/// 插入tag时,返回值为false则不插入Tag标签
typedef GenerateHashtagCallback = Future<bool> Function(
    int index, int len, String data);

class QuillController extends ChangeNotifier {
  QuillController({
    required Document document,
    required TextSelection selection,
    bool keepStyleOnNewLine = false,
    this.onReplaceText,
    this.onDelete,
    this.onSelectionCompleted,
    this.onSelectionChanged,
    this.onHashtagTriggered,
    this.onGenerateHashtagCallback,
  })  : _document = document,
        _selection = selection,
        _keepStyleOnNewLine = keepStyleOnNewLine;

  factory QuillController.basic() {
    return QuillController(
      document: Document(),
      selection: const TextSelection.collapsed(offset: 0),
    );
  }

  /// Document managed by this controller.
  Document _document;
  Document get document => _document;
  set document(doc) {
    _document = doc;

    // Prevent the selection from
    _selection = const TextSelection(baseOffset: 0, extentOffset: 0);

    notifyListeners();
  }

  /// Tells whether to keep or reset the [toggledStyle]
  /// when user adds a new line.
  final bool _keepStyleOnNewLine;

  /// Currently selected text within the [document].
  TextSelection get selection => _selection;
  TextSelection _selection;

  /// Custom [replaceText] handler
  /// Return false to ignore the event
  ReplaceTextCallback? onReplaceText;

  /// Custom delete handler
  DeleteCallback? onDelete;

  /// Custom Hashtag triggered
  HashtagCallback? onHashtagTriggered;

  GenerateHashtagCallback? onGenerateHashtagCallback;

  void Function()? onSelectionCompleted;
  void Function(TextSelection textSelection)? onSelectionChanged;

  /// Store any styles attribute that got toggled by the tap of a button
  /// and that has not been applied yet.
  /// It gets reset after each format action within the [document].
  Style toggledStyle = Style();

  bool ignoreFocusOnTextChange = false;

  /// Skip requestKeyboard being called in
  /// RawEditorState#_didChangeTextEditingValue
  bool skipRequestKeyboard = false;

  /// True when this [QuillController] instance has been disposed.
  ///
  /// A safety mechanism to ensure that listeners don't crash when adding,
  /// removing or listeners to this instance.
  bool _isDisposed = false;

  // item1: Document state before [change].
  //
  // item2: Change delta applied to the document.
  //
  // item3: The source of this change.
  Stream<Tuple3<Delta, Delta, ChangeSource>> get changes => document.changes;

  TextEditingValue get plainTextEditingValue => TextEditingValue(
        text: document.toPlainText(),
        selection: selection,
      );

  /// Only attributes applied to all characters within this range are
  /// included in the result.
  Style getSelectionStyle() {
    return document
        .collectStyle(selection.start, selection.end - selection.start)
        .mergeAll(toggledStyle);
  }

  // Increases or decreases the indent of the current selection by 1.
  void indentSelection(bool isIncrease) {
    final indent = getSelectionStyle().attributes[Attribute.indent.key];
    if (indent == null) {
      if (isIncrease) {
        formatSelection(Attribute.indentL1);
      }
      return;
    }
    if (indent.value == 1 && !isIncrease) {
      formatSelection(Attribute.clone(Attribute.indentL1, null));
      return;
    }
    if (isIncrease) {
      formatSelection(Attribute.getIndentLevel(indent.value + 1));
      return;
    }
    formatSelection(Attribute.getIndentLevel(indent.value - 1));
  }

  /// Returns all styles for each node within selection
  List<Tuple2<int, Style>> getAllIndividualSelectionStyles() {
    final styles = document.collectAllIndividualStyles(
        selection.start, selection.end - selection.start);
    return styles;
  }

  /// Returns plain text for each node within selection
  String getPlainText() {
    final text =
        document.getPlainText(selection.start, selection.end - selection.start);
    return text;
  }

  /// Returns all styles for any character within the specified text range.
  List<Style> getAllSelectionStyles() {
    final styles = document.collectAllStyles(
        selection.start, selection.end - selection.start)
      ..add(toggledStyle);
    return styles;
  }

  void undo() {
    final tup = document.undo();
    if (tup.item1) {
      _handleHistoryChange(tup.item2);
    }
  }

  void _handleHistoryChange(int? len) {
    if (len! != 0) {
      // if (this.selection.extentOffset >= document.length) {
      // // cursor exceeds the length of document, position it in the end
      // updateSelection(
      // TextSelection.collapsed(offset: document.length), ChangeSource.LOCAL);
      updateSelection(
          TextSelection.collapsed(offset: selection.baseOffset + len),
          ChangeSource.LOCAL);
    } else {
      // no need to move cursor
      notifyListeners();
    }
  }

  void redo() {
    final tup = document.redo();
    if (tup.item1) {
      _handleHistoryChange(tup.item2);
    }
  }

  bool get hasUndo => document.hasUndo;

  bool get hasRedo => document.hasRedo;

  /// clear editor
  void clear() {
    replaceText(0, plainTextEditingValue.text.length - 1, '',
        const TextSelection.collapsed(offset: 0));
  }

  // NOVA : NOVAAPP-269 由於非英文輸入法是刪除後再插入，所以需要保持選擇狀態
  bool boldStyle = false;

  void replaceText(
    int index,
    int len,
    Object? data,
    TextSelection? textSelection, {
    bool ignoreFocus = false,
  }) {
    assert(data is String || data is Embeddable);

    if (onReplaceText != null && !onReplaceText!(index, len, data)) {
      return;
    }

    if (len > 0 || data is! String || data.isNotEmpty) {
      if (boldStyle) {
        toggledStyle = toggledStyle.put(const BoldAttribute());
      } else {
        toggledStyle =
            toggledStyle.put(Attribute.clone(const BoldAttribute(), null));
      }
    }

    // [[START]]: GTStudio : Hashtag handler =====
    if (_isHashtagSymbol(data)) {
      toggledStyle = toggledStyle.put(const HashtagAttribute());
      _onHashtagCallback(index, len, data as String);
    }

    var isHashtagActivating = _isHashtagAttributeToggled(index);
    var isHashtagComplete = false;

    if (isHashtagActivating) {
      isHashtagComplete = _isHashtagEndingSymbol(data);

      if (!isHashtagComplete) {
        _onHashtagCallback(index, len, data as String);
      }

      isHashtagActivating = !isHashtagComplete;
    } // [[END]]: GTStudio : Hashtag handler =====

    Delta? delta;
    if (len > 0 || data is! String || data.isNotEmpty) {
      delta = document.replace(index, len, data);
      var shouldRetainDelta = toggledStyle.isNotEmpty &&
              delta.isNotEmpty &&
              delta.length <= 2 &&
              delta.last.isInsert ||
          // NOVA : NOVAAPP-269 非英文輸入法的情況，比如輸入a點擊選擇中文字'啊'，會多一步刪除的操作
          (delta.length == 3 && delta[1].isInsert && delta.last.isDelete);

      if (shouldRetainDelta &&
          toggledStyle.isNotEmpty &&
          delta.length == 2 &&
          delta.last.data == '\n') {
        // if all attributes are inline, shouldRetainDelta should be false
        final anyAttributeNotInline =
            toggledStyle.values.any((attr) => !attr.isInline);
        if (!anyAttributeNotInline) {
          shouldRetainDelta = false;
        }
      }

      // [START]: GTStudio: Replace hashtag attribute as Embed.
      if (isHashtagComplete) {
        final hashtagSymbolIndex = _indexOfHashtagFromCurrent(index);
        final hashtagString =
            document.toPlainText().substring(hashtagSymbolIndex, index);
        final embedHashtag = InlineBlockEmbed.hashTag(hashtagString);

        void disableStyleOfWhitespaceEndSymbol() {
          formatText(index, 1, Attribute.clone(const HashtagAttribute(), null));
        }

        if (data is String && data != hashtagSymbol) {
          disableStyleOfWhitespaceEndSymbol();
        }

        _onGenerateHashtagCallback(
                hashtagSymbolIndex, hashtagString.length, hashtagString)
            .then((value) {
          if (value) {
            document.replace(
                hashtagSymbolIndex, hashtagString.length, embedHashtag);
            // Move cursor behind hashtag embed
            textSelection =
                TextSelection.collapsed(offset: hashtagSymbolIndex + 1);
          }
        });
        shouldRetainDelta = false;
      } // [END]: GTStudio: Replace hashtag attribute as Embed.

      if (shouldRetainDelta && !isHashtagActivating) {
        var retainDelta = Delta();
        //  NOVA : NOVAAPP-269 移除多餘的刪除的操作，讓屬性切換正常
        if (retainDelta.length > 2 && retainDelta.last.isDelete) {
          retainDelta = retainDelta.slice(0, retainDelta.length - 1);
        }
        retainDelta
          ..retain(index)
          ..retain(data is String ? data.length : 1, toggledStyle.toJson());
        document.compose(retainDelta, ChangeSource.LOCAL);
      }
    }

    if (_keepStyleOnNewLine) {
      final style = getSelectionStyle();
      final notInlineStyle = style.attributes.values.where((s) => !s.isInline);
      toggledStyle = style.removeAll(notInlineStyle.toSet());
    } else {
      toggledStyle = Style();
    }

    if (textSelection != null) {
      if (delta == null || delta.isEmpty) {
        _updateSelection(textSelection!, ChangeSource.LOCAL);
      } else {
        final user = Delta()
          ..retain(index)
          ..insert(data)
          ..delete(len);
        final positionDelta = getPositionDelta(user, delta);
        _updateSelection(
          textSelection!.copyWith(
            baseOffset: textSelection!.baseOffset + positionDelta,
            extentOffset: textSelection!.extentOffset + positionDelta,
          ),
          ChangeSource.LOCAL,
        );
      }
    }

    if (ignoreFocus) {
      ignoreFocusOnTextChange = true;
    }
    notifyListeners();
    ignoreFocusOnTextChange = false;
  }

  bool _isHashtagEndingSymbol(Object? data) =>
      // Check end symbol(whitespace/another hashtag)
      (_isHashtagSymbol(data)) || _isWhiteSpace(data) || _isNewLine(data);

  bool _isNewLine(Object? data) => data is String && data == '\n';

  bool _isWhiteSpace(Object? data) => data is String && data == '\u0020';

  bool _isHashtagSymbol(Object? data) =>
      data is String && data == hashtagSymbol;

  bool _isHashtagAttributeToggled(int index) {
    return document
        .collectStyle(index > 0 ? index - 1 : index, 1)
        .containsKey(Attribute.hashtag.key);
  }

  void _onHashtagCallback(int index, int len, String currentChar) {
    final hashtagIndex = _indexOfHashtagFromCurrent(index);
    final hashtagString = document.toPlainText().substring(hashtagIndex, index);
    onHashtagTriggered?.call(index, len, hashtagString + currentChar);
  }

  Future<bool> _onGenerateHashtagCallback(
      int index, int len, String hashtagString) async {
    if (onGenerateHashtagCallback == null) {
      return Future<bool>.value(true);
    }
    return await onGenerateHashtagCallback!.call(index, len, hashtagString);
  }

  static const String hashtagSymbol = '#';

  /// Define forward search index of hashtag symbol method.
  int _indexOfHashtagFromCurrent(int currentIndex) {
    final plainText = document.toPlainText();
    for (var pos = currentIndex - 1; pos >= 0; pos--) {
      final char = plainText.substring(pos, pos + 1);
      if (char == hashtagSymbol) return pos;
    }
    return currentIndex;
  }

  /// Called in two cases:
  /// forward == false && textBefore.isEmpty
  /// forward == true && textAfter.isEmpty
  /// Android only
  /// see https://github.com/singerdmx/flutter-quill/discussions/514
  void handleDelete(int cursorPosition, bool forward) =>
      onDelete?.call(cursorPosition, forward);

  void formatTextStyle(int index, int len, Style style) {
    style.attributes.forEach((key, attr) {
      formatText(index, len, attr);
    });
  }

  void formatText(int index, int len, Attribute? attribute) {
    if (len == 0 &&
        attribute!.isInline &&
        attribute.key != Attribute.link.key) {
      // Add the attribute to our toggledStyle.
      // It will be used later upon insertion.
      toggledStyle = toggledStyle.put(attribute);
    }

    final change = document.format(index, len, attribute);
    // Transform selection against the composed change and give priority to
    // the change. This is needed in cases when format operation actually
    // inserts data into the document (e.g. embeds).
    final adjustedSelection = selection.copyWith(
        baseOffset: change.transformPosition(selection.baseOffset),
        extentOffset: change.transformPosition(selection.extentOffset));
    if (selection != adjustedSelection) {
      _updateSelection(adjustedSelection, ChangeSource.LOCAL);
    }
    notifyListeners();
  }

  void formatSelection(Attribute? attribute) {
    formatText(selection.start, selection.end - selection.start, attribute);
  }

  void moveCursorToStart() {
    updateSelection(
        const TextSelection.collapsed(offset: 0), ChangeSource.LOCAL);
  }

  void moveCursorToPosition(int position) {
    updateSelection(
        TextSelection.collapsed(offset: position), ChangeSource.LOCAL);
  }

  void moveCursorToEnd() {
    updateSelection(
        TextSelection.collapsed(offset: plainTextEditingValue.text.length),
        ChangeSource.LOCAL);
  }

  void updateSelection(TextSelection textSelection, ChangeSource source) {
    _updateSelection(textSelection, source);
    notifyListeners();
  }

  void compose(Delta delta, TextSelection textSelection, ChangeSource source) {
    if (delta.isNotEmpty) {
      document.compose(delta, source);
    }

    textSelection = selection.copyWith(
        baseOffset: delta.transformPosition(selection.baseOffset, force: false),
        extentOffset:
            delta.transformPosition(selection.extentOffset, force: false));
    if (selection != textSelection) {
      _updateSelection(textSelection, source);
    }

    notifyListeners();
  }

  @override
  void addListener(VoidCallback listener) {
    // By using `_isDisposed`, make sure that `addListener` won't be called on a
    // disposed `ChangeListener`
    if (!_isDisposed) {
      super.addListener(listener);
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    // By using `_isDisposed`, make sure that `removeListener` won't be called
    // on a disposed `ChangeListener`
    if (!_isDisposed) {
      super.removeListener(listener);
    }
  }

  @override
  void dispose() {
    if (!_isDisposed) {
      document.close();
    }

    _isDisposed = true;
    super.dispose();
  }

  void _updateSelection(TextSelection textSelection, ChangeSource source) {
    _selection = textSelection;
    final end = document.length - 1;
    _selection = selection.copyWith(
        baseOffset: math.min(selection.baseOffset, end),
        extentOffset: math.min(selection.extentOffset, end));
    toggledStyle = Style();
    onSelectionChanged?.call(textSelection);
  }

  /// Given offset, find its leaf node in document
  Leaf? queryNode(int offset) {
    return document.querySegmentLeafNode(offset).item2;
  }

  /// Clipboard for image url and its corresponding style
  /// item1 is url and item2 is style string
  Tuple2<String, String>? _copiedImageUrl;

  Tuple2<String, String>? get copiedImageUrl => _copiedImageUrl;

  set copiedImageUrl(Tuple2<String, String>? value) {
    _copiedImageUrl = value;
    Clipboard.setData(const ClipboardData(text: ''));
  }

  // Notify toolbar buttons directly with attributes
  Map<String, Attribute> toolbarButtonToggler = {};
}
