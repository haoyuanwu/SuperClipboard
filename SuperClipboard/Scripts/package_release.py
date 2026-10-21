#!/usr/bin/env python3
"""Build and package one macOS architecture without changing the source checkout."""
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
REPOSITORY = PROJECT.parent


def run(*args):
    subprocess.run([str(value) for value in args], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--version', default='1.0.0')
    parser.add_argument('--arch', choices=['arm64', 'x86_64'], required=True)
    parser.add_argument('--derived-data', type=Path)
    parser.add_argument('--packages', type=Path, default=Path('/tmp/SuperClipboardSourcePackages'))
    parser.add_argument('--output', type=Path, default=PROJECT / 'dist')
    parser.add_argument('--skip-build', action='store_true')
    args = parser.parse_args()
    derived = args.derived_data or Path(tempfile.gettempdir()) / f'SuperClipboardRelease-{args.arch}'
    if not args.skip_build:
        run('xcodebuild', '-quiet', '-project', PROJECT / 'SuperClipboard.xcodeproj',
            '-scheme', 'SuperClipboard', '-configuration', 'Release',
            '-destination', 'generic/platform=macOS', '-derivedDataPath', derived,
            '-clonedSourcePackagesDirPath', args.packages,
            f'ARCHS={args.arch}', 'ONLY_ACTIVE_ARCH=NO', 'CODE_SIGNING_ALLOWED=NO',
            f'MARKETING_VERSION={args.version}', 'CURRENT_PROJECT_VERSION=1', 'build')
    source = derived / 'Build/Products/Release/SuperClipboard.app'
    if not source.is_dir():
        raise SystemExit(f'Missing build product: {source}')
    metadata = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    if metadata.get('CFBundleShortVersionString') != args.version:
        raise SystemExit('Build product version does not match requested version')
    binary = source / 'Contents/MacOS/SuperClipboard'
    architectures = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip()
    if architectures != args.arch:
        raise SystemExit(f'Unexpected architecture: {architectures}')
    args.output.mkdir(parents=True, exist_ok=True)
    dmg = args.output / f'SuperClipboard-{args.version}-{args.arch}.dmg'
    if dmg.exists():
        raise SystemExit(f'Refusing to overwrite: {dmg}')
    with tempfile.TemporaryDirectory(prefix=f'SuperClipboard-{args.arch}-') as directory:
        staging = Path(directory) / 'image'
        staging.mkdir()
        app = staging / 'SuperClipboard.app'
        shutil.copytree(source, app, symlinks=True)
        (staging / 'Applications').symlink_to('/Applications', target_is_directory=True)
        shutil.copy2(PROJECT / 'docs/FEATURES.zh-CN.md', staging / '功能介绍.md')
        shutil.copy2(REPOSITORY / 'CHANGELOG.md', staging / '更新记录.md')
        license_source = args.packages / 'checkouts/MediaToolSwift/LICENSE'
        if not license_source.is_file():
            raise SystemExit(f'Missing dependency license: {license_source}')
        notices = app / 'Contents/Resources/ThirdPartyNotices'
        notices.mkdir(parents=True, exist_ok=True)
        shutil.copy2(license_source, notices / 'MediaToolSwift-MPL-2.0.txt')
        (notices / 'README.txt').write_text(
            'MediaToolSwift 2.1.0\nSource: https://github.com/starkdmi/MediaToolSwift/tree/2.1.0\n'
            'License: Mozilla Public License 2.0\nThe dependency is used without source modifications.\n')
        run('codesign', '--force', '--deep', '--sign', '-', app)
        run('codesign', '--verify', '--deep', '--strict', '--verbose=2', app)
        run('hdiutil', 'create', '-volname', f'SuperClipboard {args.version}',
            '-srcfolder', staging, '-format', 'UDZO', '-ov', dmg)
    run('hdiutil', 'verify', dmg)
    digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
    dmg.with_suffix('.dmg.sha256').write_text(f'{digest}  {dmg.name}\n')
    manifest = {'version': args.version, 'architecture': architectures, 'minimumMacOS': metadata.get('LSMinimumSystemVersion'),
                'signature': 'ad-hoc', 'notarized': False, 'sha256': digest, 'filename': dmg.name}
    dmg.with_suffix('.manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Packaged and verified: {dmg}')


if __name__ == '__main__':
    main()
