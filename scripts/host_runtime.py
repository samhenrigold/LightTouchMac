"""Link the real HostRuntime package into standalone host/session probes."""
import os
from pathlib import Path
import subprocess


def swift_flags(root):
    package = root / 'Packages/HostRuntime'
    environment = dict(os.environ)
    environment.setdefault('CLANG_MODULE_CACHE_PATH', str(root / '.build/host-runtime-modules'))
    scratch = root / '.build/host-runtime'
    subprocess.run(['swift', 'build', '--build-system', 'native', '--disable-sandbox',
                    '--package-path', str(package), '--scratch-path', str(scratch),
                    '--product', 'HostRuntime'], env=environment, check=True,
                   stdout=subprocess.DEVNULL)
    output = subprocess.check_output(['swift', 'build', '--build-system', 'native', '--disable-sandbox',
                    '--package-path', str(package), '--scratch-path', str(scratch),
                    '--show-bin-path'], env=environment, text=True).strip()
    return ['-module-cache-path', environment['CLANG_MODULE_CACHE_PATH'],
            '-I', str(Path(output) / 'Modules'), '-L', output, '-lHostRuntime',
            '-Xfrontend', '-import-module', '-Xfrontend', 'HostRuntime']
