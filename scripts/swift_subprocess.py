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
    return ['-I', str(built),
        *[arg for path in maps for arg in ['-Xcc', '-fmodule-map-file=' + str(path)]],
        *[str(built / (name + '.o')) for name in ['Subprocess', 'SystemPackage', 'CSystem', '_SubprocessCShims']]]
