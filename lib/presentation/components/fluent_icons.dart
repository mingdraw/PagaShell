// Fluent UI System Icons: assets/Panel Left/SVG/ic_fluent_panel_left_24_*.svg
// Source: https://github.com/microsoft/fluentui-system-icons
//
// MIT License
//
// Copyright (c) 2020 Microsoft Corporation
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

/// 补充当前 iconify_flutter 未包含的 Fluent 侧栏 SVG。
abstract final class Fluent {
  // 保持 Iconify 的图标标识，便于与官方集合核对。
  // ignore: constant_identifier_names
  static const String panel_left_24_filled =
      '<svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">'
      '<path d="M5.25 4C3.45507 4 2 5.45507 2 7.25V16.75C2 18.5449 3.45508 20 5.25 20H18.75C20.5449 20 22 18.5449 22 16.75V7.25C22 5.45507 20.5449 4 18.75 4H5.25ZM18.75 5.5C19.7165 5.5 20.5 6.2835 20.5 7.25V16.75C20.5 17.7165 19.7165 18.5 18.75 18.5H9.5V5.5H18.75Z" fill="#212121"/>'
      '</svg>';

  // ignore: constant_identifier_names
  static const String panel_left_24_regular =
      '<svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">'
      '<path d="M2 7.25C2 5.45507 3.45507 4 5.25 4H18.75C20.5449 4 22 5.45507 22 7.25V16.75C22 18.5449 20.5449 20 18.75 20H5.25C3.45508 20 2 18.5449 2 16.75V7.25ZM9.5 5.5V18.5H18.75C19.7165 18.5 20.5 17.7165 20.5 16.75V7.25C20.5 6.2835 19.7165 5.5 18.75 5.5H9.5ZM8 5.5H5.25C4.2835 5.5 3.5 6.2835 3.5 7.25V16.75C3.5 17.7165 4.2835 18.5 5.25 18.5H8V5.5Z" fill="#212121"/>'
      '</svg>';
}
