#!/usr/bin/env python3
"""Check the complete arm64 macOS load closure before packaging or signing."""
import argparse
import pathlib
import re
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def version(value):
    parts = tuple(map(int, value.split('.')))
    return parts + (0,) * (3 - len(parts))


def metadata(path):
    if 'arm64' not in run('lipo', '-archs', str(path)).split():
        raise ValueError(f'{path}: missing arm64 slice')
    deps, rpaths, minimum = [], [], None
    for block in re.split(r'Load command \d+\n', run('otool', '-arch', 'arm64', '-l', str(path)))[1:]:
        command = re.search(r'\bcmd (\S+)', block).group(1)
        if command in ('LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB', 'LC_LOAD_UPWARD_DYLIB'):
            deps.append(re.search(r'\bname (.+) \(offset', block).group(1))
        elif command == 'LC_RPATH':
            rpaths.append(re.search(r'\bpath (.+) \(offset', block).group(1))
        elif command == 'LC_BUILD_VERSION':
            platform = re.search(r'\bplatform (\S+)', block).group(1)
            if platform not in ('1', 'MACOS'):
                raise ValueError(f'{path}: not a macOS binary (platform {platform})')
            minimum = re.search(r'\bminos (\S+)', block).group(1)
        elif command == 'LC_VERSION_MIN_MACOSX':
            minimum = re.search(r'\bversion (\S+)', block).group(1)
    if minimum is None:
        raise ValueError(f'{path}: missing macOS deployment target')
    return deps, rpaths, minimum


def system(path):
    return path.startswith(('/usr/lib/', '/System/Library/'))


def expand(path, loader, executable):
    return pathlib.Path(path.replace('@loader_path', str(loader)).replace('@executable_path', str(executable)))


def dependencies(path, inherited=(), executable=None):
    deps, rpaths, minimum = metadata(path)
    executable = executable or path.parent
    search = [expand(p, path.parent, executable) for p in rpaths] + list(inherited)
    resolved = []
    for dep in deps:
        if system(dep):
            continue
        if dep.startswith('@rpath/'):
            candidates = [p / dep[len('@rpath/'):] for p in search]
        else:
            candidates = [expand(dep, path.parent, executable)]
        target = next((p.resolve() for p in candidates if p.is_file()), None)
        if target is None:
            raise ValueError(f'{path}: unresolved dependency {dep}')
        resolved.append((dep, target))
    return resolved, search, minimum


def check(path, target, bundle=None, inherited=(), executable=None, seen=None):
    seen = set() if seen is None else seen
    path = path.resolve()
    if path in seen:
        return
    seen.add(path)
    deps, search, minimum = dependencies(path, inherited, executable)
    if version(minimum) > version(target):
        raise ValueError(f'{path}: requires macOS {minimum}, app supports {target}')
    print(f'macOS {minimum}: {path}')
    for name, dep in deps:
        if bundle and (name.startswith('/') or not dep.is_relative_to(bundle.resolve())):
            raise ValueError(f'{path}: dependency escapes relocatable bundle: {name}')
        check(dep, target, bundle, search, executable, seen)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--minos', default='14.0')
    parser.add_argument('--bundle', type=pathlib.Path)
    parser.add_argument('--deps', action='store_true')
    parser.add_argument('--rpaths', action='store_true')
    parser.add_argument('paths', type=pathlib.Path, nargs='+')
    args = parser.parse_args()
    try:
        for path in args.paths:
            if args.rpaths:
                print('\n'.join(metadata(path)[1]))
            elif args.deps:
                for name, dep in dependencies(path.resolve())[0]:
                    print(f'{name}\t{dep}')
            else:
                executable = path.resolve().parent
                if args.bundle and path.suffix == '.dylib':
                    executable = args.bundle / 'Contents/MacOS'
                check(path, args.minos, args.bundle, executable=executable)
    except (ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))


if __name__ == '__main__':
    main()
