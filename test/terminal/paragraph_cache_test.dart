import 'dart:ui' show Paragraph;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagashell/terminal/paga_terminal.dart';
import 'package:pagashell/terminal/src/ui/painter.dart';
import 'package:pagashell/terminal/src/ui/paragraph_cache.dart';

Paragraph _layout(String text) =>
    ParagraphCache.layout(text, const TextStyle(), TextScaler.noScaling);

void main() {
  test('字形键精确区分码点、颜色与样式', () {
    const content = 0x41 | (1 << CellContent.widthShift);
    final keys = {
      ParagraphCache.glyphKey(content, 0xFFFFFFFF, 0),
      ParagraphCache.glyphKey(content, 0xFFFFFFFE, 0),
      ParagraphCache.glyphKey(content, 0xFFFFFFFF, ParagraphCache.bold),
      ParagraphCache.glyphKey(content + 1, 0xFFFFFFFF, 0),
      ParagraphCache.glyphKey(
        0x41 | (2 << CellContent.widthShift),
        0xFFFFFFFF,
        0,
      ),
    };
    expect(keys, hasLength(5));
  });

  test('超出容量时淘汰最久未用的条目并释放', () {
    final cache = ParagraphCache(2);
    addTearDown(cache.clear);
    final a = cache.putGlyph(1, _layout('a'));
    final b = cache.putGlyph(2, _layout('b'));
    expect(cache.glyph(1), same(a)); // a 变为最近使用
    final c = cache.putCluster('é', 3, _layout('é'));

    expect(cache.length, 2);
    expect(cache.glyph(2), isNull);
    expect(b.debugDisposed, isTrue);
    expect(cache.glyph(1), same(a));
    expect(cache.cluster('é', 3), same(c));
    expect(a.debugDisposed, isFalse);
  });

  test('只剩新条目所在表时淘汰另一张表，不淘汰刚放入的条目', () {
    final cache = ParagraphCache(1);
    addTearDown(cache.clear);
    final old = cache.putCluster('x', 0, _layout('x'));
    final fresh = cache.putGlyph(1, _layout('a'));
    expect(old.debugDisposed, isTrue);
    expect(fresh.debugDisposed, isFalse);
    expect(cache.glyph(1), same(fresh));
  });

  test('同一字体样式共享缓存，最后一个引用释放时清空', () {
    const style = TerminalStyle(fontSize: 11);
    final first = ParagraphCache.acquire(style, TextScaler.noScaling);
    final second = ParagraphCache.acquire(style, TextScaler.noScaling);
    expect(second, same(first));
    final glyph = first.putGlyph(1, _layout('a'));

    ParagraphCache.release(style, TextScaler.noScaling);
    expect(glyph.debugDisposed, isFalse);
    ParagraphCache.release(style, TextScaler.noScaling);
    expect(glyph.debugDisposed, isTrue);
    expect(
      ParagraphCache.acquire(style, TextScaler.noScaling),
      isNot(same(first)),
    );
    ParagraphCache.release(style, TextScaler.noScaling);
  });

  group('未绘制终端的共享缓存引用', () {
    const style = TerminalStyle(fontSize: 17);
    const scaler = TextScaler.noScaling;
    late ParagraphCache activeCache;
    late Paragraph glyph;
    TerminalPainter? painter;

    setUp(() {
      activeCache = ParagraphCache.acquire(style, scaler);
      glyph = activeCache.putGlyph(1, _layout('a'));
      painter = TerminalPainter(
        theme: TerminalThemes.defaultTheme,
        textStyle: style,
        textScaler: scaler,
      );
    });

    tearDown(() {
      painter?.dispose();
      ParagraphCache.release(style, scaler);
      expect(glyph.debugDisposed, isTrue);
    });

    test('销毁时保留其他终端正在使用的字形', () {
      painter!.dispose();
      painter = null;

      expect(glyph.debugDisposed, isFalse);
      expect(activeCache.glyph(1), same(glyph));
    });

    test('更换字体样式时保留其他终端正在使用的字形', () {
      painter!.textStyle = const TerminalStyle(fontSize: 19);

      expect(glyph.debugDisposed, isFalse);
      expect(activeCache.glyph(1), same(glyph));
    });

    test('更换文字缩放时保留其他终端正在使用的字形', () {
      painter!.textScaler = const TextScaler.linear(2);

      expect(glyph.debugDisposed, isFalse);
      expect(activeCache.glyph(1), same(glyph));
    });
  });
}
