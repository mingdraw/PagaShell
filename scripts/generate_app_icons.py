#!/usr/bin/env python3
"""Export the PagaShell artwork to native desktop icon resources.

Requires Pillow: python3 -m pip install Pillow
Run from any directory: python3 scripts/generate_app_icons.py
"""

import argparse
from pathlib import Path

try:
    from PIL import Image
except ImportError as error:
    raise SystemExit('Install Pillow: python3 -m pip install Pillow') from error


ROOT = Path(__file__).resolve().parents[1]
MAC_SIZES = (16, 32, 64, 128, 256, 512, 1024)
WINDOWS_SIZES = (16, 24, 32, 48, 64, 128, 256)
LINUX_SIZES = (16, 24, 32, 48, 64, 128, 256, 512)


def export_pngs(image: Image.Image, directory: Path, sizes: tuple[int, ...]) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    for size in sizes:
        image.resize((size, size), Image.Resampling.LANCZOS).save(
            directory / f'app_icon_{size}.png', optimize=True
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        '--source',
        type=Path,
        default=ROOT / 'assets/branding/pagashell-icon-v1.png',
        help='Square master PNG, at least 1024px wide',
    )
    args = parser.parse_args()
    with Image.open(args.source) as source:
        if source.width != source.height or source.width < 1024:
            parser.error('The source must be square and at least 1024px wide.')
        image = source.convert('RGBA')

    export_pngs(
        image, ROOT / 'macos/Runner/Assets.xcassets/AppIcon.appiconset', MAC_SIZES
    )
    windows_icon = ROOT / 'windows/runner/resources/app_icon.ico'
    windows_icon.parent.mkdir(parents=True, exist_ok=True)
    image.resize((256, 256), Image.Resampling.LANCZOS).save(
        windows_icon, format='ICO', sizes=[(size, size) for size in WINDOWS_SIZES]
    )
    export_pngs(image, ROOT / 'linux/runner/resources', LINUX_SIZES)
    print('Updated macOS AppIcon, Windows ICO and Linux PNG resources.')


if __name__ == '__main__':
    main()
