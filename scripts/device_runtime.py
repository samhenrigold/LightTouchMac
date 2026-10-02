"""Import and link the single typed helper/session owner used by the GUI."""
import os
from pathlib import Path
import subprocess


def swift_flags(root, *, target=None):
    environment = dict(os.environ)
    suffix = '-' + target if target else ''
    environment.setdefault('CLANG_MODULE_CACHE_PATH', str(root / ('.build/device-runtime-modules' + suffix)))
    scratch = root / ('.build/device-runtime' + suffix)
    target_flags = ['--triple', target] if target else []
    command = ['swift', 'build', '--build-system', 'native', '--disable-sandbox',
               '--package-path', str(root / 'Shared'), '--scratch-path', str(scratch), *target_flags]
    subprocess.run([*command, '--product', 'DeviceRuntime'], env=environment,
                   check=True, stdout=subprocess.DEVNULL)
    output = subprocess.check_output([*command, '--show-bin-path'], env=environment, text=True).strip()
    return ['-module-cache-path', environment['CLANG_MODULE_CACHE_PATH'],
            '-I', str(Path(output) / 'Modules'), '-I', str(root / 'Shared/CLink'),
            '-L', output, '-lDeviceRuntime',
            '-Xfrontend', '-import-module', '-Xfrontend', 'DeviceRuntime',
            '-Xfrontend', '-import-module', '-Xfrontend', 'HostRuntime']
