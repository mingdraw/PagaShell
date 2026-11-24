#!/usr/bin/env python3
"""Generate monochrome system tray icon assets for macOS, Windows, and Linux.

The monochrome mark mirrors the foreground silhouette of PagaShell's app icon
(terminal chevron `>` connected via a rounded fork to two stacked server modules
with circular status dot cutouts), optically tuned for small menu bar / taskbar
sizes.

Requires Pillow: python3 -m pip install Pillow
Run from any directory: python3 scripts/generate_tray_icons.py
"""

from __future__ import annotations

import json
import math
from pathlib import Path

try:
    from PIL import Image
except ImportError as error:
    raise SystemExit('Install Pillow: python3 -m pip install Pillow') from error


ROOT = Path(__file__).resolve().parents[1]

VIEWBOX_W = 28.0
VIEWBOX_H = 24.0

# Monochrome color palettes:
# - macOS template image uses pure black with alpha (AppKit tints automatically).
# - Light foreground (#FFFFFF) is rendered on dark taskbars / panels.
# - Dark foreground (#1A1A1A) is rendered on light taskbars / panels.
MAC_TEMPLATE_COLOR = (0, 0, 0)
LIGHT_FG_COLOR = (255, 255, 255)
DARK_FG_COLOR = (26, 26, 26)

WINDOWS_ICO_SIZES = (16, 20, 24, 32, 48, 64)
LINUX_PNG_SIZES = (24, 48)


def _dist_segment(
    px: float, py: float, ax: float, ay: float, bx: float, by: float
) -> float:
    vx, vy = bx - ax, by - ay
    wx, wy = px - ax, py - ay
    denom = vx * vx + vy * vy
    t = 0.0 if denom == 0.0 else max(0.0, min(1.0, (wx * vx + wy * vy) / denom))
    return math.hypot(px - (ax + t * vx), py - (ay + t * vy))


def _dist_round_rect(
    px: float,
    py: float,
    x0: float,
    y0: float,
    x1: float,
    y1: float,
    r: float,
) -> float:
    cx = (x0 + x1) * 0.5
    cy = (y0 + y1) * 0.5
    hx = (x1 - x0) * 0.5 - r
    hy = (y1 - y0) * 0.5 - r
    qx = abs(px - cx) - hx
    qy = abs(py - cy) - hy
    return math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - r


def _dist_arc(
    px: float,
    py: float,
    cx: float,
    cy: float,
    radius: float,
    a0: float,
    a1: float,
) -> float:
    ang = math.atan2(py - cy, px - cx)
    while ang < a0 - math.pi:
        ang += 2.0 * math.pi
    while ang > a1 + math.pi:
        ang -= 2.0 * math.pi
    if a0 <= ang <= a1:
        return abs(math.hypot(px - cx, py - cy) - radius)
    p0x, p0y = cx + radius * math.cos(a0), cy + radius * math.sin(a0)
    p1x, p1y = cx + radius * math.cos(a1), cy + radius * math.sin(a1)
    return min(math.hypot(px - p0x, py - p0y), math.hypot(px - p1x, py - p1y))


def _dist_fork(
    px: float,
    py: float,
    x_start: float,
    x_vert: float,
    x_end: float,
    y_mid: float,
    y_top: float,
    y_bot: float,
    corner_r: float,
) -> float:
    d_stem = _dist_segment(px, py, x_start, y_mid, x_vert, y_mid)
    d_vert = _dist_segment(
        px, py, x_vert, y_top + corner_r, x_vert, y_bot - corner_r
    )
    d_top_arc = _dist_arc(
        px,
        py,
        x_vert + corner_r,
        y_top + corner_r,
        corner_r,
        math.pi,
        1.5 * math.pi,
    )
    d_top_h = _dist_segment(px, py, x_vert + corner_r, y_top, x_end, y_top)
    d_bot_arc = _dist_arc(
        px,
        py,
        x_vert + corner_r,
        y_bot - corner_r,
        corner_r,
        0.5 * math.pi,
        math.pi,
    )
    d_bot_h = _dist_segment(px, py, x_vert + corner_r, y_bot, x_end, y_bot)
    return min(d_stem, d_vert, d_top_arc, d_top_h, d_bot_arc, d_bot_h)


def pagashell_tray_sdf(x: float, y: float) -> float:
    """Signed distance field for PagaShell's monochrome mark in a 28x24 viewBox."""
    # Bold '>' command chevron extending slightly above/below the server stack.
    d_chevron = (
        min(
            _dist_segment(x, y, 3.0, 5.1, 9.6, 12.0),
            _dist_segment(x, y, 3.0, 18.9, 9.6, 12.0),
        )
        - 1.48
    )
    # Sleek rounded-corner fork connecting chevron apex to the two server modules.
    d_fork = (
        _dist_fork(
            x,
            y,
            x_start=9.6,
            x_vert=13.8,
            x_end=16.8,
            y_mid=12.0,
            y_top=7.45,
            y_bot=16.55,
            corner_r=1.75,
        )
        - 0.90
    )
    # Two stacked rounded-rectangle server modules with circular status cutouts.
    d_srv_top = _dist_round_rect(x, y, 16.4, 4.3, 26.4, 10.6, 2.0)
    d_srv_bot = _dist_round_rect(x, y, 16.4, 13.4, 26.4, 19.7, 2.0)
    d_dot_top = math.hypot(x - 23.4, y - 7.45) - 1.22
    d_dot_bot = math.hypot(x - 23.4, y - 16.55) - 1.22
    d_servers = max(min(d_srv_top, d_srv_bot), -min(d_dot_top, d_dot_bot))
    return min(d_chevron, d_fork, d_servers)


def render_tray_icon(
    width: int, height: int, color: tuple[int, int, int]
) -> Image.Image:
    """Render the monochrome mark with analytic subpixel anti-aliasing."""
    image = Image.new('RGBA', (width, height), (0, 0, 0, 0))
    pixels = image.load()
    scale = min(width / VIEWBOX_W, height / VIEWBOX_H)
    ox_px = (width - VIEWBOX_W * scale) * 0.5
    oy_px = (height - VIEWBOX_H * scale) * 0.5
    inv_scale = 1.0 / scale
    aa_radius = 0.52 * inv_scale
    offsets = ((-0.25, -0.25), (0.25, -0.25), (-0.25, 0.25), (0.25, 0.25))
    r, g, b = color

    for iy in range(height):
        for ix in range(width):
            coverage = 0.0
            for dx, dy in offsets:
                x = (ix + 0.5 + dx - ox_px) * inv_scale
                y = (iy + 0.5 + dy - oy_px) * inv_scale
                d = pagashell_tray_sdf(x, y)
                coverage += max(0.0, min(1.0, 0.5 - d / (2.0 * aa_radius)))
            alpha = int(round(coverage * 0.25 * 255.0))
            if alpha > 0:
                pixels[ix, iy] = (r, g, b, alpha)
    return image


def _rounded_rect_with_dot_path(
    x: float, y: float, w: float, h: float, r: float, cx: float, cy: float, dr: float
) -> str:
    return (
        f'M {x + r:.2f} {y:.2f} '
        f'H {x + w - r:.2f} '
        f'A {r:.2f} {r:.2f} 0 0 1 {x + w:.2f} {y + r:.2f} '
        f'V {y + h - r:.2f} '
        f'A {r:.2f} {r:.2f} 0 0 1 {x + w - r:.2f} {y + h:.2f} '
        f'H {x + r:.2f} '
        f'A {r:.2f} {r:.2f} 0 0 1 {x:.2f} {y + h - r:.2f} '
        f'V {y + r:.2f} '
        f'A {r:.2f} {r:.2f} 0 0 1 {x + r:.2f} {y:.2f} Z '
        f'M {cx + dr:.2f} {cy:.2f} '
        f'A {dr:.2f} {dr:.2f} 0 1 0 {cx - dr:.2f} {cy:.2f} '
        f'A {dr:.2f} {dr:.2f} 0 1 0 {cx + dr:.2f} {cy:.2f} Z'
    )


def build_svg(*, square: bool, symbolic: bool) -> str:
    """Build matching monochrome SVG markup using pure fill/stroke & evenodd."""
    vb_h = 28 if square else 24
    y_offset = 2.0 if square else 0.0
    style_block = (
        '  <style id="current-color-scheme" type="text/css">\n'
        '    .ColorScheme-Text { color: #232629; }\n'
        '  </style>\n'
        if symbolic
        else ''
    )
    group_attrs = (
        'class="ColorScheme-Text"'
        if symbolic
        else 'style="color:#000000"'
    )
    top_srv = _rounded_rect_with_dot_path(
        16.4, 4.3 + y_offset, 10.0, 6.3, 2.0, 23.4, 7.45 + y_offset, 1.22
    )
    bot_srv = _rounded_rect_with_dot_path(
        16.4, 13.4 + y_offset, 10.0, 6.3, 2.0, 23.4, 16.55 + y_offset, 1.22
    )
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 28 {vb_h}" '
        f'width="28" height="{vb_h}">\n'
        f'{style_block}'
        f'  <g {group_attrs}>\n'
        f'    <path d="M 3.00 {5.10 + y_offset:.2f} L 9.60 {12.00 + y_offset:.2f} '
        f'L 3.00 {18.90 + y_offset:.2f}" '
        f'fill="none" stroke="currentColor" stroke-width="2.96" '
        f'stroke-linecap="round" stroke-linejoin="round"/>\n'
        f'    <path d="M 9.60 {12.00 + y_offset:.2f} H 13.80 '
        f'M 13.80 {12.00 + y_offset:.2f} V {9.20 + y_offset:.2f} '
        f'A 1.75 1.75 0 0 1 15.55 {7.45 + y_offset:.2f} H 16.80 '
        f'M 13.80 {12.00 + y_offset:.2f} V {14.80 + y_offset:.2f} '
        f'A 1.75 1.75 0 0 0 15.55 {16.55 + y_offset:.2f} H 16.80" '
        f'fill="none" stroke="currentColor" stroke-width="1.80" '
        f'stroke-linecap="round" stroke-linejoin="round"/>\n'
        f'    <path d="{top_srv}" fill="currentColor" fill-rule="evenodd"/>\n'
        f'    <path d="{bot_srv}" fill="currentColor" fill-rule="evenodd"/>\n'
        f'  </g>\n'
        f'</svg>\n'
    )


def export_macos_template_imageset() -> None:
    imageset = ROOT / 'macos/Runner/Assets.xcassets/TrayIcon.imageset'
    imageset.mkdir(parents=True, exist_ok=True)
    render_tray_icon(22, 18, MAC_TEMPLATE_COLOR).save(
        imageset / 'tray_icon_1x.png', optimize=True
    )
    render_tray_icon(44, 36, MAC_TEMPLATE_COLOR).save(
        imageset / 'tray_icon_2x.png', optimize=True
    )
    contents = {
        'images': [
            {
                'filename': 'tray_icon_1x.png',
                'idiom': 'mac',
                'scale': '1x',
            },
            {
                'filename': 'tray_icon_2x.png',
                'idiom': 'mac',
                'scale': '2x',
            },
        ],
        'info': {
            'author': 'xcode',
            'version': 1,
        },
        'properties': {
            'template-rendering-intent': 'template',
        },
    }
    (imageset / 'Contents.json').write_text(
        json.dumps(contents, indent=2) + '\n', encoding='utf-8'
    )


def export_windows_ico(path: Path, color: tuple[int, int, int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    frames = [render_tray_icon(size, size, color) for size in WINDOWS_ICO_SIZES]
    # Save largest frame first with individually SDF-rendered smaller frames
    # so 16/20/24/32px sizes stay razor sharp without downscaling blur.
    frames[-1].save(
        path,
        format='ICO',
        sizes=[(size, size) for size in WINDOWS_ICO_SIZES],
        append_images=frames[:-1],
    )


def export_linux_resources() -> None:
    directory = ROOT / 'linux/runner/resources'
    directory.mkdir(parents=True, exist_ok=True)
    for size in LINUX_PNG_SIZES:
        render_tray_icon(size, size, LIGHT_FG_COLOR).save(
            directory / f'tray_icon_light_{size}.png', optimize=True
        )
        render_tray_icon(size, size, DARK_FG_COLOR).save(
            directory / f'tray_icon_dark_{size}.png', optimize=True
        )
    (directory / 'pagashell-symbolic.svg').write_text(
        build_svg(square=True, symbolic=True), encoding='utf-8'
    )


def main() -> None:
    branding_svg = ROOT / 'assets/branding/pagashell-tray-icon.svg'
    branding_svg.parent.mkdir(parents=True, exist_ok=True)
    branding_svg.write_text(
        build_svg(square=False, symbolic=False), encoding='utf-8'
    )

    export_macos_template_imageset()
    export_windows_ico(
        ROOT / 'windows/runner/resources/tray_icon_light.ico', LIGHT_FG_COLOR
    )
    export_windows_ico(
        ROOT / 'windows/runner/resources/tray_icon_dark.ico', DARK_FG_COLOR
    )
    export_linux_resources()
    print(
        'Generated monochrome tray icons for macOS (Template), '
        'Windows (light/dark ICO), and Linux (light/dark PNG + symbolic SVG).'
    )


if __name__ == '__main__':
    main()
