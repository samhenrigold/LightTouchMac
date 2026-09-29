#!/usr/bin/env python3
"""Fetch pinned dependency archives or stage tracked source without build outputs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


DEFAULT_MANIFEST = Path(__file__).resolve().parent.parent / 'build-support/dependencies.json'


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def read_manifest(path, group):
    manifest = json.loads(path.read_text())
    if manifest.get('schema_version') != 1:
        raise ValueError(f'unsupported source manifest: {path}')
    packages = [p for p in manifest['packages'] if group in p['groups']]
    if not packages:
        raise ValueError(f'no sources declared for group {group}')
    names = set()
    for package in packages:
        for filename in [package['archive'], *package.get('cache_aliases', [])]:
            if Path(filename).name != filename or filename in ('.', '..'):
                raise ValueError(f'invalid archive name: {filename}')
        if package['archive'] in names:
            raise ValueError(f'duplicate archive: {package["archive"]}')
        names.add(package['archive'])
        if not re.fullmatch(r'[0-9a-f]{64}', package['sha256']):
            raise ValueError(f'invalid SHA-256 for {package["name"]}')
        if not package['url'].startswith('https://'):
            raise ValueError(f'source URL must use HTTPS: {package["url"]}')
    return packages


def verified(path, expected):
    actual = sha256(path)
    if actual != expected:
        raise ValueError(f'SHA-256 mismatch: {path}\nexpected {expected}\nactual   {actual}')


def fetch(args):
    packages = read_manifest(args.manifest, args.group)
    destination = args.destination.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    records = []
    for package in packages:
        output = destination / package['archive']
        if output.exists():
            verified(output, package['sha256'])
            origin = str(output)
        else:
            cached = next((cache / filename for cache in args.cache
                           for filename in [package['archive'], *package.get('cache_aliases', [])]
                           if (cache / filename).is_file()), None)
            if cached:
                # A corrupt cache must fail loudly, even when the network is available.
                verified(cached, package['sha256'])
            elif args.offline:
                raise ValueError(f'offline source missing: {package["archive"]}')
            descriptor, temporary_name = tempfile.mkstemp(prefix='.download-', dir=destination)
            os.close(descriptor)
            temporary = Path(temporary_name)
            try:
                if cached:
                    shutil.copyfile(cached, temporary)
                    origin = str(cached.resolve())
                else:
                    print(f'Fetching {package["archive"]}', flush=True)
                    subprocess.run(['curl', '--fail', '--location', '--show-error',
                                    '--proto', '=https', '--proto-redir', '=https',
                                    '--output', str(temporary), package['url']], check=True)
                    origin = package['url']
                verified(temporary, package['sha256'])
                temporary.replace(output)
            finally:
                temporary.unlink(missing_ok=True)
        records.append({**package, 'path': str(output), 'obtained_from': origin})
    write_json(destination / f'{args.group}-sources.json', {
        'schema_version': 1, 'manifest_sha256': sha256(args.manifest), 'packages': records,
    })


def git(source, *args):
    return subprocess.check_output(['git', '-C', str(source), *args])


def stage_git(args):
    source, destination = args.source.resolve(), args.destination.resolve()
    if destination.exists():
        raise ValueError(f'use a fresh source destination: {destination}')
    tracked = git(source, 'ls-files', '-z').decode().split('\0')
    untracked = git(source, 'ls-files', '--others', '--exclude-standard', '-z').decode().split('\0')
    untracked = [p for p in untracked if p and Path(p).name != '.DS_Store']
    if untracked:
        raise ValueError(f'{source}: untracked files would be omitted; add source to Git first: '
                         + ', '.join(untracked[:10]))
    records = []
    destination.mkdir(parents=True)
    for name in sorted(tracked):
        if not name or Path(name).name == '.DS_Store':
            continue
        original, target = source / name, destination / name
        if not original.exists() and not original.is_symlink():
            continue  # Preserve tracked deletions in the working tree.
        if not original.resolve().is_relative_to(source):
            raise ValueError(f'tracked source escapes repository: {original}')
        if original.is_dir():
            raise ValueError(f'submodule requires an explicit source recipe: {original}')
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(original, target, follow_symlinks=False)
        records.append({'path': name, 'sha256': sha256(target),
                        'executable': bool(target.stat().st_mode & 0o111)})
    diff = git(source, 'diff', '--binary', 'HEAD', '--', '.', ':(exclude).DS_Store')
    write_json(args.record, {
        'schema_version': 1, 'source': str(source), 'staged_source': str(destination),
        'commit': git(source, 'rev-parse', 'HEAD').decode().strip(),
        'tracked_diff_sha256': hashlib.sha256(diff).hexdigest(),
        'modified': bool(diff), 'files': records,
    })


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    download = commands.add_parser('fetch', help='verify archives before exposing them to a build')
    download.add_argument('--manifest', type=Path, default=DEFAULT_MANIFEST)
    download.add_argument('--group', choices=['native', 'static', 'tools', 'swiftpm'], required=True)
    download.add_argument('--destination', type=Path, required=True)
    download.add_argument('--cache', type=Path, action='append', default=[])
    download.add_argument('--offline', action='store_true')
    download.set_defaults(action=fetch)
    staging = commands.add_parser('stage-git', help='copy tracked working files into a clean build tree')
    staging.add_argument('--source', type=Path, required=True)
    staging.add_argument('--destination', type=Path, required=True)
    staging.add_argument('--record', type=Path, required=True)
    staging.set_defaults(action=stage_git)
    args = parser.parse_args()
    try:
        args.action(args)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))


if __name__ == '__main__':
    main()
