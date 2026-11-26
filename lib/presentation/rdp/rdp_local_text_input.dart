import 'package:flutter/services.dart';

/// A local IME buffer for a remote surface. Only committed text crosses RDP.
class RdpLocalTextInput with TextInputClient {
  RdpLocalTextInput(this.onCommit);

  final ValueChanged<String> onCommit;
  static const _empty = TextEditingValue(
    selection: TextSelection.collapsed(offset: 0),
  );
  TextInputConnection? _connection;
  TextEditingValue _value = _empty;
  String _committed = '';
  String _clearedPrefix = '';
  final _localKeys = <PhysicalKeyboardKey>{};
  Offset? _anchor;
  Size? _viewSize;

  bool get attached => _connection?.attached ?? false;

  void open(int viewId) {
    if (attached) return;
    _connection = TextInput.attach(
      this,
      TextInputConfiguration(
        viewId: viewId,
        inputAction: TextInputAction.none,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
      ),
    );
    _connection!.setEditingState(_empty);
    _connection!.show();
    _sendAnchor();
  }

  void close() {
    _connection?.close();
    connectionClosed();
  }

  void setAnchor(Offset globalPosition, Size viewSize) {
    if (_anchor == globalPosition && _viewSize == viewSize) return;
    _anchor = globalPosition;
    _viewSize = viewSize;
    _sendAnchor();
  }

  void _sendAnchor() {
    if (!attached || _anchor == null || _viewSize == null) return;
    final rect = _anchor! & const Size(1, 20);
    _connection!
      ..setEditableSizeAndTransform(_viewSize!, Matrix4.identity())
      ..setCaretRect(rect)
      ..setComposingRect(rect);
  }

  /// Leave text and composition keys to the platform. A key that went to
  /// either side keeps the same route until released.
  bool handlesKey(KeyEvent event) {
    if (!attached) return false;
    final physical = event.physicalKey;
    if (event is KeyUpEvent) return _localKeys.remove(physical);
    if (_localKeys.contains(physical)) return true;
    if (event is KeyRepeatEvent) return false;
    final keyboard = HardwareKeyboard.instance;
    final logical = event.logicalKey;
    final character = event.character;
    final printable =
        (character != null &&
            !LogicalKeyboardKey.isControlCharacter(character)) ||
        (logical.keyId & LogicalKeyboardKey.planeMask) ==
            LogicalKeyboardKey.unicodePlane;
    final altGraph = keyboard.logicalKeysPressed.contains(
      LogicalKeyboardKey.altGraph,
    );
    final shortcut =
        keyboard.isMetaPressed ||
        (!altGraph && (keyboard.isControlPressed || keyboard.isAltPressed));
    final composing =
        _value.isComposingRangeValid && !_value.composing.isCollapsed;
    if (logical == LogicalKeyboardKey.process ||
        (!shortcut && (printable || composing))) {
      _localKeys.add(physical);
      return true;
    }
    return false;
  }

  @override
  TextEditingValue get currentTextEditingValue => _value;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    if (!attached) return;
    _value = value;
    if (value.isComposingRangeValid && !value.composing.isCollapsed) return;

    // Keep a short emitted prefix so consecutive platform edits that arrive
    // before a reset do not retransmit earlier letters.
    final late =
        _clearedPrefix.isNotEmpty && value.text.startsWith(_clearedPrefix);
    final prefix = late ? _clearedPrefix : _committed;
    final added = value.text.startsWith(prefix)
        ? value.text.substring(prefix.length)
        : '';
    if (late || value.text.length >= 256 || !value.text.startsWith(prefix)) {
      _clearedPrefix = value.text;
      _committed = '';
      _value = _empty;
      _connection!.setEditingState(_empty);
    } else {
      _clearedPrefix = '';
      _committed = value.text;
    }
    if (added.isNotEmpty) onCommit(added);
  }

  @override
  void connectionClosed() {
    _connection = null;
    _value = _empty;
    _committed = '';
    _clearedPrefix = '';
    _localKeys.clear();
  }

  @override
  void performAction(TextInputAction action) {}

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}
}
