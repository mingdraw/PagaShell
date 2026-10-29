#!/usr/bin/env python3
"""Verify native desktop binaries and package one GitHub Release asset."""

import argparse
import re
import shutil
import struct
import subprocess
import tarfile
import tempfile
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def check_version(tag):
    if not re.fullmatch(r'v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', tag):
        raise ValueError(f'Invalid release tag: {tag}')
    match = re.search(r'^version:\s*(\S+)', (ROOT / 'pubspec.yaml').read_text(), re.M)
    if match is None or match[1].split('+')[0] != tag[1:]:
        raise ValueError('Release tag does not match pubspec.yaml version')


def check_binary(path, platform, arch):
    with path.open('rb') as binary:
        header = binary.read(64)
        if platform == 'linux':
            expected = 62 if arch == 'amd64' else 183
            if header[:5] != b'\x7fELF\x02' or int.from_bytes(header[18:20], 'little') != expected:
                raise ValueError(f'Unexpected ELF architecture: {path}')
        elif platform == 'windows':
            if header[:2] != b'MZ':
                raise ValueError(f'Invalid PE binary: {path}')
            binary.seek(struct.unpack_from('<I', header, 60)[0])
            pe = binary.read(6)
            expected = 0x8664 if arch == 'amd64' else 0xAA64
            if pe[:4] != b'PE\0\0' or struct.unpack_from('<H', pe, 4)[0] != expected:
                raise ValueError(f'Unexpected PE architecture: {path}')
        else:
            expected = 'x86_64' if arch == 'amd64' else 'arm64'
            subprocess.run(['lipo', '-verify_arch', expected, str(path)], check=True)


def package(platform, arch, version):
    check_version(version)
    flutter_arch = 'x64' if arch == 'amd64' else 'arm64'
    if platform == 'linux':
        source = ROOT / 'build/linux' / flutter_arch / 'release/bundle'
        executable = source / 'pagashell'
        rust_library = source / 'lib/librust_lib_pagashell.so'
    elif platform == 'windows':
        source = ROOT / 'build/windows' / flutter_arch / 'runner/Release'
        executable = source / 'pagashell.exe'
        rust_library = source / 'rust_lib_pagashell.dll'
    else:
        source = ROOT / 'build/macos/Build/Products/Release/pagashell.app'
        executable = source / 'Contents/MacOS/pagashell'
        rust_library = None  # Cargokit statically links Rust into the app.

    check_binary(executable, platform, arch)
    if rust_library is not None:
        check_binary(rust_library, platform, arch)
    if platform == 'windows':
        for library in source.glob('*.dll'):
            check_binary(library, platform, arch)

    output = ROOT / 'dist'
    output.mkdir(exist_ok=True)
    name = f'pagashell_{version}_{platform}_{arch}'
    with tempfile.TemporaryDirectory(prefix='pagashell-release-') as temporary:
        staging = Path(temporary) / name
        staging.mkdir()
        if platform == 'macos':
            subprocess.run(['ditto', str(source), str(staging / 'PagaShell.app')], check=True)
            (staging / 'Applications').symlink_to('/Applications')
        else:
            shutil.copytree(source, staging, dirs_exist_ok=True)
        shutil.copy2(ROOT / 'README.md', staging)
        shutil.copy2(ROOT / 'LICENSE', staging)
        if platform == 'windows':
            archive = output / f'{name}.zip'
            with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as zipped:
                for item in sorted(staging.rglob('*')):
                    if item.is_file():
                        zipped.write(item, item.relative_to(staging.parent))
        elif platform == 'linux':
            archive = output / f'{name}.tar.gz'
            with tarfile.open(archive, 'w:gz') as tar:
                tar.add(staging, arcname=name)
        else:
            archive = output / f'{name}.dmg'
            subprocess.run([
                'hdiutil', 'create', '-volname', f'PagaShell {version}',
                '-srcfolder', str(staging), '-ov', '-format', 'UDZO', str(archive),
            ], check=True)
    print(archive)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-version')
    parser.add_argument('--platform', choices=['linux', 'macos', 'windows'])
    parser.add_argument('--arch', choices=['amd64', 'arm64'])
    parser.add_argument('--version')
    args = parser.parse_args()
    if args.check_version:
        check_version(args.check_version)
        return
    if not all([args.platform, args.arch, args.version]):
        parser.error('--platform, --arch and --version are required for packaging')
    package(args.platform, args.arch, args.version)


if __name__ == '__main__':
    main()
