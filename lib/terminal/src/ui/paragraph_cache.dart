import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:pagashell/terminal/src/ui/terminal_text_style.dart';

/// 已排版字形的 LRU 缓存，同一字体样式的终端共享一份。
///
/// 键是精确值而非哈希：单码点字形把码点/宽度、解析后的 ARGB 颜色和
/// 粗体/斜体/下划线打包进一个 int（共 59 位），组合字符另以文本加样式为键，
/// 因此不会出现哈希碰撞画错字形。背景色只在 inverse 时影响前景，调用方
/// 传入的已是解析后的颜色，同一字符在不同背景下共用条目。
class ParagraphCache {
  ParagraphCache(this.maximumSize);

  final int maximumSize;

  // 默认 Map 保持插入顺序：命中时移到末尾，首个键即最久未用。
  final Map<int, Paragraph> _glyphs = {};
  final Map<(String, int), Paragraph> _clusters = {};

  static const bold = 1;
  static const italic = 2;
  static const underline = 4;

  /// 单码点字形的键。[content] 为单元格的码点与宽度位（24 位），
  /// [color] 为 ARGB32，[styleFlags] 为 [bold]/[italic]/[underline] 组合。
  @pragma('vm:prefer-inline')
  static int glyphKey(int content, int color, int styleFlags) =>
      (color << 27) | (styleFlags << 24) | (content & 0xFFFFFF);

  /// 组合字符的样式部分。
  @pragma('vm:prefer-inline')
  static int clusterStyle(int color, int styleFlags) =>
      (color << 3) | styleFlags;

  Paragraph? glyph(int key) => _touch(_glyphs, key);

  Paragraph? cluster(String text, int style) =>
      _touch(_clusters, (text, style));

  Paragraph putGlyph(int key, Paragraph paragraph) =>
      _put(_glyphs, key, paragraph);

  Paragraph putCluster(String text, int style, Paragraph paragraph) =>
      _put(_clusters, (text, style), paragraph);

  /// 排版 [text]，供 [putGlyph] / [putCluster] 缓存。
  static Paragraph layout(String text, TextStyle style, TextScaler scaler) {
    final builder = ParagraphBuilder(style.getParagraphStyle());
    builder.pushStyle(style.getTextStyle(textScaler: scaler));
    builder.addText(text);
    final paragraph = builder.build();
    paragraph.layout(const ParagraphConstraints(width: double.infinity));
    return paragraph;
  }

  @pragma('vm:prefer-inline')
  Paragraph? _touch<K>(Map<K, Paragraph> map, K key) {
    final paragraph = map.remove(key);
    if (paragraph != null) map[key] = paragraph;
    return paragraph;
  }

  Paragraph _put<K>(Map<K, Paragraph> map, K key, Paragraph value) {
    map.remove(key)?.dispose();
    map[key] = value;
    // 已录制进 Picture 的字形保存的是排好的文本数据，提前释放不影响重放。
    // 优先淘汰同一张表里最久未用的条目，绝不淘汰刚放入的这一条。
    while (length > maximumSize) {
      final Map<Object, Paragraph> victim = map.length > 1
          ? map as Map<Object, Paragraph>
          : identical(map, _glyphs)
          ? _clusters
          : _glyphs;
      if (victim.isEmpty) break;
      victim.remove(victim.keys.first)!.dispose();
    }
    return value;
  }

  /// Clears the cache. This should be called when the same text and style
  /// pair no longer produces the same layout. For example, when a font is
  /// loaded.
  void clear() {
    for (final paragraph in _glyphs.values) {
      paragraph.dispose();
    }
    for (final paragraph in _clusters.values) {
      paragraph.dispose();
    }
    _glyphs.clear();
    _clusters.clear();
  }

  /// Returns the number of [Paragraph]s in the cache.
  int get length => _glyphs.length + _clusters.length;

  // 按字体样式与缩放共享，引用计数归零时释放。
  static final _shared = <(TerminalStyle, TextScaler), _SharedCache>{};

  /// 取得 [style] 与 [scaler] 对应的共享缓存；用完调用 [release]。
  static ParagraphCache acquire(TerminalStyle style, TextScaler scaler) {
    final entry = _shared.putIfAbsent((
      style,
      scaler,
    ), () => _SharedCache(ParagraphCache(10240)));
    entry.references++;
    return entry.cache;
  }

  static void release(TerminalStyle style, TextScaler scaler) {
    final key = (style, scaler);
    final entry = _shared[key];
    if (entry == null || --entry.references > 0) return;
    _shared.remove(key);
    entry.cache.clear();
  }

  /// 系统字体变化后排版结果不再有效，清空全部共享缓存。
  static void clearAll() {
    for (final entry in _shared.values) {
      entry.cache.clear();
    }
  }

  @visibleForTesting
  static int get sharedCount => _shared.length;
}

class _SharedCache {
  _SharedCache(this.cache);

  final ParagraphCache cache;
  int references = 0;
}
