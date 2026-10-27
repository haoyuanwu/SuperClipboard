#!/usr/bin/env python3
"""一条命令完成版本更新、验证、双架构打包、中文提交与 GitHub 发布。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import subprocess
import sys
from package_release import APP_DISPLAY_NAME, ARTIFACT_PREFIX

PROJECT = Path(__file__).resolve().parents[1]
ROOT = PROJECT.parent
OUTPUT = PROJECT / 'dist'
PACKAGES = Path('/tmp/SuperClipboardSourcePackages')


def run(*args, capture=False, check=True):
    result = subprocess.run([str(x) for x in args], cwd=ROOT, check=check,
                            text=True, stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else result.returncode


def files():
    raw = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT)
    return sorted({name.decode() for name in raw.split(b'\0') if name and
                   '/xcuserdata/' not in name.decode() and not name.decode().endswith('.xcuserstate')})


def source_digest():
    digest = hashlib.sha256()
    for name in files():
        path = ROOT / name
        digest.update(name.encode() + b'\0')
        digest.update(path.read_bytes() if path.is_file() else b'<deleted>')
    return digest.hexdigest()


def notes(version):
    text = (ROOT / 'CHANGELOG.md').read_text()
    section = re.search(r'^## ' + re.escape(version) + r'[^\n]*\n(.*?)(?=^## |\Z)', text, re.M | re.S)
    if not section:
        raise SystemExit(f'更新记录中找不到 {version}')
    return section.group(1).strip() + '''\n\n### 下载与安装\n\n- Apple Silicon：下载 arm64.dmg；Intel Mac：下载 x86_64.dmg。\n- 系统要求 macOS 14 或更高版本；打开 DMG 后拖入 Applications。\n- 安装包使用临时签名，尚未经过 Developer ID 签名和 Apple 公证。\n- 每个安装包附 SHA-256 校验文件、构建清单和第三方许可说明。\n'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True, help='例如 1.2.0')
    parser.add_argument('--build-number', type=int, help='首次发布新版本时默认递增')
    parser.add_argument('--prepare-only', action='store_true', help='更新、验证和打包，暂不提交或上传')
    args = parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
        parser.error('版本号格式应为 1.2.0')
    gh = shutil.which('gh') or str(Path.home() / '.local/bin/gh')
    if not args.prepare_only:
        if not Path(gh).is_file() and not shutil.which(gh):
            raise SystemExit('请先安装 GitHub CLI 并运行 gh auth login')
        run(gh, 'auth', 'status')
    if run('git', 'branch', '--show-current', capture=True) != 'main':
        raise SystemExit('请在 main 分支执行发布；脚本不会自动合并或切换分支')
    remote = run('git', 'remote', 'get-url', 'origin', capture=True)
    match = re.search(r'github\.com[:/](?:[^/@]+@)?([^/]+/[^/]+?)(?:\.git)?$', remote)
    if not match:
        raise SystemExit('origin 不是可识别的 GitHub 仓库')
    repo = match.group(1)
    # Refuse to overwrite an existing release/tag with different source.
    tag = run('git', 'rev-parse', '-q', '--verify', 'refs/tags/' + args.version,
              capture=True, check=False)
    head = run('git', 'rev-parse', 'HEAD', capture=True)
    if tag and tag != head:
        raise SystemExit('此版本标签已指向其他提交，请使用新版本号')

    project = PROJECT / 'SuperClipboard.xcodeproj/project.pbxproj'
    text = project.read_text()
    old_version = re.search(r'MARKETING_VERSION = ([^;]+);', text).group(1)
    current_build = int(re.search(r'CURRENT_PROJECT_VERSION = (\d+);', text).group(1))
    build = args.build_number or (current_build + 1 if old_version != args.version else current_build)
    text = re.sub(r'MARKETING_VERSION = [^;]+;', f'MARKETING_VERSION = {args.version};', text)
    text = re.sub(r'CURRENT_PROJECT_VERSION = \d+;', f'CURRENT_PROJECT_VERSION = {build};', text)
    project.write_text(text)
    changelog = ROOT / 'CHANGELOG.md'
    text = changelog.read_text()
    if not re.search(r'^## ' + re.escape(args.version) + r'\b', text, re.M):
        from datetime import datetime
        from zoneinfo import ZoneInfo
        date = datetime.now(ZoneInfo('Asia/Shanghai')).date()
        text = text.replace('## 未发布\n', f'## 未发布\n\n## {args.version} — {date}\n', 1)
        changelog.write_text(text)
    readme = ROOT / 'README.md'
    readme.write_text(re.sub(r'(?:SuperClipboard|PocketCube)-\d+\.\d+\.\d+-', f'{ARTIFACT_PREFIX}-{args.version}-', readme.read_text()))
    body = notes(args.version)
    OUTPUT.mkdir(exist_ok=True)
    checkpoint = OUTPUT / f'publish-{args.version}.json'
    digest = source_digest()
    cached = json.loads(checkpoint.read_text()) if checkpoint.exists() else {}
    assets = [OUTPUT / f'{ARTIFACT_PREFIX}-{args.version}-{arch}{suffix}'
              for arch in ['arm64', 'x86_64'] for suffix in ['.dmg', '.dmg.sha256', '.manifest.json']]
    reusable = cached.get('sourceDigest') == digest and all(
        asset.exists() and hashlib.sha256(asset.read_bytes()).hexdigest() == cached.get('assets', {}).get(asset.name)
        for asset in assets)
    if not reusable:
        run('git', 'diff', '--check')
        derived = '/tmp/SuperClipboardPublishDebug'
        run('xcodebuild', '-quiet', '-project', PROJECT / 'SuperClipboard.xcodeproj',
            '-scheme', 'SuperClipboard', '-configuration', 'Debug', '-derivedDataPath', derived,
            '-clonedSourcePackagesDirPath', PACKAGES, '-destination', 'platform=macOS,arch=arm64',
            'CODE_SIGNING_ALLOWED=NO', 'build')
        for script in ['test_notebook.sh', 'test_scroll_performance.sh', 'test_transfer_shelf.sh']:
            run('bash', PROJECT / 'Scripts' / script, derived)
        for arch in ['arm64', 'x86_64']:
            for asset in assets:
                if f'-{arch}.' in asset.name:
                    asset.unlink(missing_ok=True)
            run(sys.executable, PROJECT / 'Scripts/package_release.py', '--version', args.version,
                '--arch', arch, '--packages', PACKAGES, '--output', OUTPUT)
        if source_digest() != digest:
            raise SystemExit('构建期间源文件发生变化，请重新运行发布命令')
        cached = {'version': args.version, 'sourceDigest': digest,
                  'assets': {asset.name: hashlib.sha256(asset.read_bytes()).hexdigest() for asset in assets}}
        checkpoint.write_text(json.dumps(cached, indent=2) + '\n')
    else:
        print('源文件与安装包校验一致，复用本版本已通过的测试和打包结果。', flush=True)
    if args.prepare_only:
        print(f'打包完成：{OUTPUT}；登录 GitHub 后重新运行同一命令即可发布。')
        return
    run('git', 'fetch', 'origin', 'main')
    run('git', 'merge-base', '--is-ancestor', 'origin/main', 'HEAD')
    # Only repository source files are staged; local Xcode UI state is excluded.
    paths = files()
    run('git', 'add', '-f', '--', *paths)
    changed = run('git', 'diff', '--cached', '--quiet', check=False)
    if changed == 1:
        if tag:
            raise SystemExit('已有版本标签且仍有源文件变化，请使用新版本号')
        run('git', 'commit', '-m', f'发布 {args.version}：优化悬浮中转、液态玻璃界面与发布流程')
    elif changed != 0:
        raise SystemExit('无法检查待提交内容')
    if not tag:
        run('git', 'tag', args.version)
    run('git', '-c', 'credential.helper=', '-c',
        f'credential.helper=!{shlex.quote(gh)} auth git-credential',
        'push', '--atomic', 'origin', 'main', 'refs/tags/' + args.version)
    body_path = OUTPUT / f'release-{args.version}.md'
    body_path.write_text(body)
    existing = run(gh, 'release', 'view', args.version, '--repo', repo, '--json', 'isDraft',
                   capture=True, check=False)
    if not existing:
        run(gh, 'release', 'create', args.version, '--repo', repo, '--verify-tag', '--draft',
            '--title', f'{APP_DISPLAY_NAME} {args.version}', '--notes-file', body_path)
    elif not json.loads(existing)['isDraft']:
        raise SystemExit('此版本已正式发布，不覆盖附件；如需更新请使用新版本号')
    run(gh, 'release', 'upload', args.version, *assets, '--repo', repo, '--clobber')
    uploaded = json.loads(run(gh, 'release', 'view', args.version, '--repo', repo,
                             '--json', 'assets', capture=True))['assets']
    sizes = {asset['name']: asset['size'] for asset in uploaded}
    if any(sizes.get(asset.name) != asset.stat().st_size for asset in assets):
        raise SystemExit('远端附件大小校验失败，草稿保留；重新运行脚本可续传')
    run(gh, 'release', 'edit', args.version, '--repo', repo, '--draft=false', '--latest')
    print(f'发布完成：https://github.com/{repo}/releases/tag/{args.version}')


if __name__ == '__main__':
    main()
