"""Build/link the existing pinned Subprocess target for standalone Swift probes."""
import os
from pathlib import Path
import subprocess

# Reuse already-built package products when supplied. Otherwise build only the
# existing Subprocess dependency, not the app or the preparation library.
def products(root):
    if value := os.environ.get('LTM_SUBPROCESS_PRODUCTS'):
        return Path(value), Path(os.environ['LTM_SOURCE_PACKAGES'])
    scratch = root / '.build/offline-subprocess'
    subprocess.run(['swift', 'build', '--package-path', str(root / 'Packages/FirmwareKit'),
                    '--scratch-path', str(scratch), '--target', 'Subprocess'], check=True)
    return scratch / 'debug', scratch / 'checkouts'


def swift_flags(root):
    built, checkouts = products(root)
    maps = [checkouts / 'swift-system/Sources/CSystem/include/module.modulemap',
            checkouts / 'swift-subprocess/Sources/_SubprocessCShims/include/module.modulemap']
    names = ['Subprocess', 'SystemPackage', 'CSystem', '_SubprocessCShims']
    # Xcode's package engine emits aggregate objects; native SwiftPM emits
    # Modules plus per-source objects under each target's build directory.
    if all((built / (name + '.o')).is_file() for name in names):
        modules = built
        objects = [built / (name + '.o') for name in names]
    else:
        modules = built / 'Modules'
        objects = []
        for name in names:
            target_objects = sorted((built / (name + '.build')).rglob('*.o'))
            if not target_objects:
                raise FileNotFoundError(f'No package objects for {name} in {built}')
            objects.extend(target_objects)
    return ['-I', str(modules),
        *[arg for path in maps for arg in ['-Xcc', '-fmodule-map-file=' + str(path)]],
        *map(str, objects)]
