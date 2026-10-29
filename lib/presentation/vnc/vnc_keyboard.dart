import 'package:flutter/services.dart';

/// RFB sends X11 keysyms, including the active keyboard layout's character.
int? vncKeySymbol(KeyEvent event) {
  final special = <LogicalKeyboardKey, int>{
    LogicalKeyboardKey.backspace: 0xff08,
    LogicalKeyboardKey.tab: 0xff09,
    LogicalKeyboardKey.enter: 0xff0d,
    LogicalKeyboardKey.numpadEnter: 0xff8d,
    LogicalKeyboardKey.escape: 0xff1b,
    LogicalKeyboardKey.delete: 0xffff,
    LogicalKeyboardKey.home: 0xff50,
    LogicalKeyboardKey.arrowLeft: 0xff51,
    LogicalKeyboardKey.arrowUp: 0xff52,
    LogicalKeyboardKey.arrowRight: 0xff53,
    LogicalKeyboardKey.arrowDown: 0xff54,
    LogicalKeyboardKey.pageUp: 0xff55,
    LogicalKeyboardKey.pageDown: 0xff56,
    LogicalKeyboardKey.end: 0xff57,
    LogicalKeyboardKey.insert: 0xff63,
    LogicalKeyboardKey.pause: 0xff13,
    LogicalKeyboardKey.printScreen: 0xff61,
    LogicalKeyboardKey.contextMenu: 0xff67,
    LogicalKeyboardKey.shiftLeft: 0xffe1,
    LogicalKeyboardKey.shiftRight: 0xffe2,
    LogicalKeyboardKey.controlLeft: 0xffe3,
    LogicalKeyboardKey.controlRight: 0xffe4,
    LogicalKeyboardKey.capsLock: 0xffe5,
    LogicalKeyboardKey.altLeft: 0xffe9,
    LogicalKeyboardKey.altRight: 0xffea,
    LogicalKeyboardKey.metaLeft: 0xffeb,
    LogicalKeyboardKey.metaRight: 0xffec,
    LogicalKeyboardKey.numLock: 0xff7f,
    LogicalKeyboardKey.scrollLock: 0xff14,
    LogicalKeyboardKey.f1: 0xffbe,
    LogicalKeyboardKey.f2: 0xffbf,
    LogicalKeyboardKey.f3: 0xffc0,
    LogicalKeyboardKey.f4: 0xffc1,
    LogicalKeyboardKey.f5: 0xffc2,
    LogicalKeyboardKey.f6: 0xffc3,
    LogicalKeyboardKey.f7: 0xffc4,
    LogicalKeyboardKey.f8: 0xffc5,
    LogicalKeyboardKey.f9: 0xffc6,
    LogicalKeyboardKey.f10: 0xffc7,
    LogicalKeyboardKey.f11: 0xffc8,
    LogicalKeyboardKey.f12: 0xffc9,
  };
  final known = special[event.logicalKey];
  if (known != null) return known;
  var character = event.character;
  if (character == null ||
      character.runes.length != 1 ||
      character.runes.first < 32) {
    character = event.logicalKey.keyLabel;
    if (!HardwareKeyboard.instance.isShiftPressed) {
      character = character.toLowerCase();
    }
  }
  if (character.runes.length != 1) return null;
  final rune = character.runes.single;
  if (rune < 32 || rune == 127) return null;
  return rune <= 255 ? rune : 0x01000000 | rune;
}
