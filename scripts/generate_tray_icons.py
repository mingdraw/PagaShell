#!/usr/bin/env python3
"""Generate PagaShell's tray mark and service badge for each desktop platform.

The monochrome mark mirrors the foreground silhouette of PagaShell's app icon
(terminal chevron `>` connected via a rounded fork to two stacked server modules
with circular status dot cutouts), optically tuned for small menu bar / taskbar
sizes. The service badge is a separate vector layer on macOS and is composited
into the active icon variants for Windows and Linux.

Requires Pillow: python3 -m pip install Pillow
Run from any directory: python3 scripts/generate_tray_icons.py
"""

from __future__ import annotations

import json
import math
from collections.abc import Callable
from pathlib import Path

try:
    from PIL import Image
except ImportError as error:
    raise SystemExit('Install Pillow: python3 -m pip install Pillow') from error


ROOT = Path(__file__).resolve().parents[1]

VIEWBOX_W = 28
VIEWBOX_H = 24
CENTER_Y = VIEWBOX_H / 2

# Shared geometry for the SVG and the native raster exports.
CHEVRON_X = 3.2
CHEVRON_TIP_X = 9.45
CHEVRON_TOP_Y = 4.8
CHEVRON_BOTTOM_Y = VIEWBOX_H - CHEVRON_TOP_Y
CHEVRON_HALF_WIDTH = 1.59
FORK_X = 14.0
FORK_END_X = 17.0
FORK_CORNER = 1.8
FORK_HALF_WIDTH = 1.02
SERVER_X = 16.5
SERVER_WIDTH = 9.75
SERVER_HEIGHT = 6.2
SERVER_CORNER = 1.85
SERVER_ROWS = (7.4, 16.6)
SERVER_CUTOUT_X = 23.35
SERVER_CUTOUT_RADIUS = 1.32
BADGE_X = 24.75
BADGE_Y = 20.8
BADGE_RADIUS = 2.95
BADGE_FILL_RADIUS = 2.33

# - Light foreground (#FFFFFF) is rendered on dark taskbars / panels.
# - Dark foreground (#1A1A1A) is rendered on light taskbars / panels.
LIGHT_FG_COLOR = (255, 255, 255)
DARK_FG_COLOR = (26, 26, 26)
BADGE_BORDER_COLOR = (17, 113, 58)
BADGE_FILL_COLOR = (52, 211, 110)

MAC_ICON_SIZE = (22, 18)
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
            _dist_segment(x, y, CHEVRON_X, CHEVRON_TOP_Y, CHEVRON_TIP_X, CENTER_Y),
            _dist_segment(x, y, CHEVRON_X, CHEVRON_BOTTOM_Y, CHEVRON_TIP_X, CENTER_Y),
        )
        - CHEVRON_HALF_WIDTH
    )
    # Sleek rounded-corner fork connecting chevron apex to the two server modules.
    d_fork = (
        _dist_fork(
            x,
            y,
            x_start=CHEVRON_TIP_X,
            x_vert=FORK_X,
            x_end=FORK_END_X,
            y_mid=CENTER_Y,
            y_top=SERVER_ROWS[0],
            y_bot=SERVER_ROWS[1],
            corner_r=FORK_CORNER,
        )
        - FORK_HALF_WIDTH
    )
    # Two stacked rounded-rectangle server modules with circular status cutouts.
    d_servers = min(
        max(
            _dist_round_rect(
                x,
                y,
                SERVER_X,
                row - SERVER_HEIGHT / 2,
                SERVER_X + SERVER_WIDTH,
                row + SERVER_HEIGHT / 2,
                SERVER_CORNER,
            ),
            SERVER_CUTOUT_RADIUS - math.hypot(x - SERVER_CUTOUT_X, y - row),
        )
        for row in SERVER_ROWS
    )
    return min(d_chevron, d_fork, d_servers)


def _render_shape(
    width: int,
    height: int,
    color: tuple[int, int, int],
    distance: Callable[[float, float], float],
) -> Image.Image:
    """Render a shape with analytic subpixel anti-aliasing."""
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
                d = distance(x, y)
                coverage += max(0.0, min(1.0, 0.5 - d / (2.0 * aa_radius)))
            alpha = int(round(coverage * 0.25 * 255.0))
            if alpha > 0:
                pixels[ix, iy] = (r, g, b, alpha)
    return image


def render_tray_icon(
    width: int, height: int, color: tuple[int, int, int], *, active: bool = False
) -> Image.Image:
    icon = _render_shape(width, height, color, pagashell_tray_sdf)
    if active:
        for radius, badge_color in (
            (BADGE_RADIUS, BADGE_BORDER_COLOR),
            (BADGE_FILL_RADIUS, BADGE_FILL_COLOR),
        ):
            icon.alpha_composite(
                _render_shape(
                    width,
                    height,
                    badge_color,
                    lambda x, y, r=radius: math.hypot(x - BADGE_X, y - BADGE_Y) - r,
                )
            )
    return icon


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


def _svg_document(content: str, viewbox_height: int, size: tuple[int, int]) -> str:
    width, height = size
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {VIEWBOX_W} '
        f'{viewbox_height}" width="{width}" height="{height}">\n'
        f'{content}'
        f'</svg>\n'
    )


def build_svg(
    *, square: bool = False, symbolic: bool = False, size: tuple[int, int] | None = None
) -> str:
    """Build matching monochrome SVG markup using pure fill/stroke & evenodd."""
    vb_h = VIEWBOX_W if square else VIEWBOX_H
    y_offset = (vb_h - VIEWBOX_H) / 2
    mid_y = CENTER_Y + y_offset
    top_y, bottom_y = (row + y_offset for row in SERVER_ROWS)
    style_block = (
        '  <style id="current-color-scheme" type="text/css">\n'
        '    .ColorScheme-Text { color: #232629; }\n'
        '  </style>\n'
        if symbolic
        else ''
    )
    group_attrs = ' class="ColorScheme-Text"' if symbolic else ''
    color = 'currentColor' if symbolic else '#000000'
    top_srv, bottom_srv = (
        _rounded_rect_with_dot_path(
            SERVER_X,
            row - SERVER_HEIGHT / 2,
            SERVER_WIDTH,
            SERVER_HEIGHT,
            SERVER_CORNER,
            SERVER_CUTOUT_X,
            row,
            SERVER_CUTOUT_RADIUS,
        )
        for row in (top_y, bottom_y)
    )
    arc = f'A {FORK_CORNER:.2f} {FORK_CORNER:.2f} 0 0'
    content = (
        f'{style_block}'
        f'  <g{group_attrs}>\n'
        f'    <path d="M {CHEVRON_X:.2f} {CHEVRON_TOP_Y + y_offset:.2f} '
        f'L {CHEVRON_TIP_X:.2f} {mid_y:.2f} '
        f'L {CHEVRON_X:.2f} {CHEVRON_BOTTOM_Y + y_offset:.2f}" '
        f'fill="none" stroke="{color}" stroke-width="{2 * CHEVRON_HALF_WIDTH:.2f}" '
        f'stroke-linecap="round" stroke-linejoin="round"/>\n'
        f'    <path d="M {CHEVRON_TIP_X:.2f} {mid_y:.2f} H {FORK_X:.2f} '
        f'M {FORK_X:.2f} {mid_y:.2f} V {top_y + FORK_CORNER:.2f} '
        f'{arc} 1 {FORK_X + FORK_CORNER:.2f} {top_y:.2f} H {FORK_END_X:.2f} '
        f'M {FORK_X:.2f} {mid_y:.2f} V {bottom_y - FORK_CORNER:.2f} '
        f'{arc} 0 {FORK_X + FORK_CORNER:.2f} {bottom_y:.2f} H {FORK_END_X:.2f}" '
        f'fill="none" stroke="{color}" stroke-width="{2 * FORK_HALF_WIDTH:.2f}" '
        f'stroke-linecap="round" stroke-linejoin="round"/>\n'
        f'    <path d="{top_srv}" fill="{color}" fill-rule="evenodd"/>\n'
        f'    <path d="{bottom_srv}" fill="{color}" fill-rule="evenodd"/>\n'
        '  </g>\n'
    )
    return _svg_document(content, vb_h, size or (VIEWBOX_W, vb_h))


def build_badge_svg(size: tuple[int, int]) -> str:
    circles = ''.join(
        f'  <circle cx="{BADGE_X:.2f}" cy="{BADGE_Y:.2f}" r="{radius:.2f}" '
        f'fill="{"#%02x%02x%02x" % color}"/>\n'
        for radius, color in (
            (BADGE_RADIUS, BADGE_BORDER_COLOR),
            (BADGE_FILL_RADIUS, BADGE_FILL_COLOR),
        )
    )
    return _svg_document(circles, VIEWBOX_H, size)


def export_macos_imageset(
    name: str, filename: str, svg: str, *, template: bool
) -> None:
    imageset = ROOT / 'macos/Runner/Assets.xcassets' / f'{name}.imageset'
    imageset.mkdir(parents=True, exist_ok=True)
    (imageset / filename).write_text(svg, encoding='utf-8')
    contents = {
        'images': [
            {
                'filename': filename,
                'idiom': 'mac',
            },
        ],
        'info': {
            'author': 'xcode',
            'version': 1,
        },
        'properties': {
            'preserves-vector-representation': True,
            'template-rendering-intent': 'template' if template else 'original',
        },
    }
    (imageset / 'Contents.json').write_text(
        json.dumps(contents, indent=2) + '\n', encoding='utf-8'
    )


def export_windows_ico(
    path: Path, color: tuple[int, int, int], *, active: bool
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    frames = [
        render_tray_icon(size, size, color, active=active) for size in WINDOWS_ICO_SIZES
    ]
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
    for variant, color, active in icon_variants():
        for size in LINUX_PNG_SIZES:
            render_tray_icon(size, size, color, active=active).save(
                directory / f'tray_icon_{variant}_{size}.png', optimize=True
            )
    (directory / 'pagashell-symbolic.svg').write_text(
        build_svg(square=True, symbolic=True), encoding='utf-8'
    )


def icon_variants():
    for theme, color in (('light', LIGHT_FG_COLOR), ('dark', DARK_FG_COLOR)):
        yield theme, color, False
        yield f'{theme}_active', color, True


def main() -> None:
    branding_svg = ROOT / 'assets/branding/pagashell-tray-icon.svg'
    branding_svg.parent.mkdir(parents=True, exist_ok=True)
    branding_svg.write_text(build_svg(), encoding='utf-8')

    export_macos_imageset(
        'TrayIcon', 'tray_icon.svg', build_svg(size=MAC_ICON_SIZE), template=True
    )
    export_macos_imageset(
        'TrayServiceBadge',
        'tray_service_badge.svg',
        build_badge_svg(MAC_ICON_SIZE),
        template=False,
    )
    for variant, color, active in icon_variants():
        export_windows_ico(
            ROOT / 'windows/runner/resources' / f'tray_icon_{variant}.ico',
            color,
            active=active,
        )
    export_linux_resources()
    print(
        'Generated tray icons and service badge variants for macOS, Windows, and Linux.'
    )


if __name__ == '__main__':
    main()
