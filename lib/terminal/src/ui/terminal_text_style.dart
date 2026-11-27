import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';

const _kDefaultFontSize = 13.0;

// 内置 FiraCode Nerd Font Mono 的自然行高约为 1.2308 em（2400/1950），
// 1.25 保留微小自然留白，避免负行距挤压下沉部（g/y/_）与彩色胶囊底边。
const _kDefaultHeight = 1.25;

const _kDefaultFontFamily = 'monospace';

/// 将配置中的终端字号（pt）换算为 Flutter 逻辑像素。
///
/// macOS 逻辑坐标本身即 72 DPI 点（1 pt = 1 logical px）；
/// Windows 与 Linux 以 96 DPI 为逻辑坐标基准（1 pt = 96/72 logical px）。
double terminalFontSizeToLogicalPixels(double pt, TargetPlatform platform) =>
    platform == TargetPlatform.macOS ? pt : pt * (96.0 / 72.0);

const _kDefaultFontFamilyFallback = [
  'Menlo',
  'Monaco',
  'Consolas',
  'Liberation Mono',
  'Courier New',
  'Noto Sans Mono CJK SC',
  'Noto Sans Mono CJK TC',
  'Noto Sans Mono CJK KR',
  'Noto Sans Mono CJK JP',
  'Noto Sans Mono CJK HK',
  'Noto Color Emoji',
  'Noto Sans Symbols',
  'monospace',
  'sans-serif',
];

class TerminalStyle {
  const TerminalStyle({
    this.fontSize = _kDefaultFontSize,
    this.height = _kDefaultHeight,
    this.fontFamily = _kDefaultFontFamily,
    this.fontFamilyFallback = _kDefaultFontFamilyFallback,
  });

  factory TerminalStyle.fromTextStyle(TextStyle textStyle) {
    return TerminalStyle(
      fontSize: textStyle.fontSize ?? _kDefaultFontSize,
      height: textStyle.height ?? _kDefaultHeight,
      fontFamily:
          textStyle.fontFamily ??
          textStyle.fontFamilyFallback?.first ??
          _kDefaultFontFamily,
      fontFamilyFallback:
          textStyle.fontFamilyFallback ?? _kDefaultFontFamilyFallback,
    );
  }

  final double fontSize;

  final double height;

  final String fontFamily;

  final List<String> fontFamilyFallback;

  TextStyle toTextStyle({
    Color? color,
    Color? backgroundColor,
    bool bold = false,
    bool italic = false,
    bool underline = false,
    bool strikethrough = false,
  }) {
    final decoration = underline && strikethrough
        ? TextDecoration.combine([
            TextDecoration.underline,
            TextDecoration.lineThrough,
          ])
        : underline
        ? TextDecoration.underline
        : strikethrough
        ? TextDecoration.lineThrough
        : TextDecoration.none;
    return TextStyle(
      fontSize: fontSize,
      height: height,
      leadingDistribution: TextLeadingDistribution.even,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      color: color,
      backgroundColor: backgroundColor,
      fontWeight: bold ? FontWeight.bold : FontWeight.normal,
      fontStyle: italic ? FontStyle.italic : FontStyle.normal,
      decoration: decoration,
    );
  }

  /// 构造固定支撑线（strut）的段落样式，确保中文/Emoji 等后备字体与主字体
  /// 共用同一基线与单元格高度，不在同行内上下跳动。
  ui.ParagraphStyle toParagraphStyle(TextScaler scaler) {
    final scaledSize = scaler.scale(fontSize);
    return ui.ParagraphStyle(
      fontFamily: fontFamily,
      fontSize: scaledSize,
      height: height,
      strutStyle: ui.StrutStyle(
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        fontSize: scaledSize,
        height: height,
        forceStrutHeight: true,
        leadingDistribution: TextLeadingDistribution.even,
      ),
      textHeightBehavior: const TextHeightBehavior(
        leadingDistribution: TextLeadingDistribution.even,
      ),
    );
  }

  TerminalStyle copyWith({
    double? fontSize,
    double? height,
    String? fontFamily,
    List<String>? fontFamilyFallback,
  }) {
    return TerminalStyle(
      fontSize: fontSize ?? this.fontSize,
      height: height ?? this.height,
      fontFamily: fontFamily ?? this.fontFamily,
      fontFamilyFallback: fontFamilyFallback ?? this.fontFamilyFallback,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalStyle &&
          fontSize == other.fontSize &&
          height == other.height &&
          fontFamily == other.fontFamily &&
          listEquals(fontFamilyFallback, other.fontFamilyFallback);

  @override
  int get hashCode => Object.hash(
    fontSize,
    height,
    fontFamily,
    Object.hashAll(fontFamilyFallback),
  );
}
