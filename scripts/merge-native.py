#!/usr/bin/env python3
"""Merge per-architecture native build roots into one universal root for package.sh.

Each input is a native root for a different LTM_ARCH: a build-package-native.sh
output, or a build-release.py --stage native root (its prefix and static deps
reused from --native-deps, QEMU built elsewhere). Each part is read from where the
root's native-build.json says it is. The output has the one-step layout package.sh
consumes: every Mach-O (dylibs, executables, static archives) is lipo'd; all other
files must match exactly once each slice's build paths are replaced with the output's.
iBoot32Patcher is not merged: build-release.py builds it for both slices.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

# The parts of a native root that packaging reads: output path <- native-build.json key (+ file within it).
PARTS = {'prefix': ('deps_prefix', ''), 'static/prefix': ('static_deps', ''),
         'qemu-build/libqemu-arm.dylib': ('qemu_build', 'libqemu-arm.dylib'),
         'build/usbmuxd/src/usbmuxd': ('usbmuxd_binary', '')}
# Build-time metadata for compiling against one slice; packaging never reads it, and
# cross-compiled slices legitimately differ (e.g. how Meson found zlib).
SKIPPED = ('lib/pkgconfig/', 'share/pkgconfig/')
SKIPPED_SUFFIXES = ('.la',)


def macho(path):
    with path.open('rb') as stream:
        magic = stream.read(8)
    return magic[:4] in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe') or magic == b'!<arch>\n'


def relocations(root, record, output):
    """(build path, output path) pairs for one slice, longest first: each part's recorded source (as recorded and
    resolved) becomes the output's part, then the slice's root (and the deps root it reused) the output root."""
    pairs = []
    for part, (key, _) in PARTS.items():
        for source in {Path(record[key]), Path(record[key]).resolve()}:
            pairs.append((str(source), str(output / part)))
    for source in (root, record.get('reused_native_deps')):
        if source:
            pairs += [(str(Path(source)), str(output)), (str(Path(source).resolve()), str(output))]
    return sorted(set(pairs), key=lambda pair: -len(pair[0]))


def relocated(text, pairs):
    # .pc, .la and a few installed paths name the build root; point them at the output.
    for old, new in pairs:
        text = text.replace(old.encode(), new.encode())
    return text


def relink(path, pairs, scratch):
    """Copy of a Mach-O whose install name, dependencies and rpaths name the output, not the slice's build paths."""
    if path.read_bytes()[:8] == b'!<arch>\n':
        return path
    copy = scratch / f'{len(list(scratch.iterdir()))}-{path.name}'
    shutil.copy2(path, copy)
    copy.chmod(0o755)
    edits = []
    listing = subprocess.check_output(['otool', '-l', str(copy)], text=True)
    for line in listing.splitlines():
        line = line.strip()
        if line.startswith(('name ', 'path ')):
            old = line.split(' ', 1)[1].rsplit(' (offset', 1)[0]
            new = relocated(old.encode(), pairs).decode()
            if new != old:
                edits += ['-rpath', old, new] if line.startswith('path ') else ['-change', old, new]
    install_id = subprocess.check_output(['otool', '-D', str(copy)], text=True).splitlines()[1:]
    if install_id and relocated(install_id[0].encode(), pairs).decode() != install_id[0]:
        edits += ['-id', relocated(install_id[0].encode(), pairs).decode()]
    if edits:
        subprocess.run(['install_name_tool', *edits, str(copy)], check=True, capture_output=True)
    return copy


def files(root):
    result = {}
    for path in root.rglob('*'):
        name = str(path.relative_to(root))
        if (path.is_file() or path.is_symlink()) and not (
                name.startswith(SKIPPED) or name.endswith(SKIPPED_SUFFIXES)):
            result[name] = path
    return result


def merge(output, part, slices, scratch):
    """slices: {arch: (root, record)}."""
    target_root = output.resolve() / part
    key, member = PARTS[part]
    trees = []
    for root, record in slices.values():
        source = Path(record[key]) / member if member else Path(record[key])
        pairs = relocations(root, record, output.resolve())
        trees.append((pairs, {'': source} if source.is_file() else files(source)))
    names = set(trees[0][1])
    for _, tree in trees[1:]:
        if set(tree) != names:
            raise ValueError(f'{part}: file lists differ: {sorted(names ^ set(tree))[:5]}')
    for name in sorted(names):
        inputs = [(pairs, tree[name]) for pairs, tree in trees]
        target = target_root / name if name else target_root
        target.parent.mkdir(parents=True, exist_ok=True)
        first = inputs[0][1]
        if first.is_symlink():
            links = {str(path.readlink()) for _, path in inputs}
            if len(links) != 1:
                raise ValueError(f'{part}/{name}: symlink targets differ')
            target.symlink_to(links.pop())
        elif macho(first):
            thin = [relink(path, pairs, scratch) for pairs, path in inputs]
            subprocess.run(['lipo', '-create', *map(str, thin), '-output', str(target)], check=True)
            shutil.copymode(first, target)
            if thin[0] != first:  # relinked, so arm64 needs a fresh ad-hoc signature
                subprocess.run(['codesign', '-f', '-s', '-', str(target)], check=True, capture_output=True)
        else:
            contents = {relocated(path.read_bytes(), pairs) for pairs, path in inputs}
            if len(contents) != 1:
                raise ValueError(f'{part}/{name}: differs between architectures and is not a Mach-O')
            target.write_bytes(contents.pop())
            shutil.copymode(first, target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='New output directory')
    parser.add_argument('slices', type=Path, nargs='+', help='Native build roots, one per architecture')
    args = parser.parse_args()
    if args.output.exists():
        sys.exit(f'Output already exists: {args.output}')
    slices = {}
    for root in args.slices:
        record = json.loads((root / 'native-build.json').read_text())
        arch = record['architecture']
        if arch in slices:
            sys.exit(f'Two native roots for {arch}: {slices[arch][0]} and {root}')
        slices[arch] = (root.resolve(), record)
    try:
        with tempfile.TemporaryDirectory() as scratch:
            for part in PARTS:
                merge(args.output, part, slices, Path(scratch))
    except (ValueError, subprocess.CalledProcessError) as error:
        shutil.rmtree(args.output, ignore_errors=True)
        sys.exit(str(error))
    record = {'schema_version': 1, 'architectures': sorted(slices),
              'static_deps': str(args.output.resolve() / 'static/prefix'),
              'slices': {arch: record for arch, (_, record) in sorted(slices.items())}}
    (args.output / 'native-build.json').write_text(json.dumps(record, indent=2) + '\n')
    print(f'Universal native root ({", ".join(sorted(slices))}): {args.output}')


if __name__ == '__main__':
    main()
