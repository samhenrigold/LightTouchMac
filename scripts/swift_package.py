"""Small SwiftPM product/link boundary for standalone runtime probes."""
import os
from pathlib import Path
import subprocess


def product_flags(root, *, package, product, cache, target=None):
    """Build only the requested product; isolate foreign target outputs/caches."""
    environment = dict(os.environ)
    suffix = '-' + target if target else ''
    environment.setdefault('CLANG_MODULE_CACHE_PATH', str(root / ('.build/' + cache + '-modules' + suffix)))
    scratch = root / ('.build/' + cache + suffix)
    target_flags = ['--triple', target] if target else []
    command = ['swift', 'build', '--build-system', 'native', '--disable-sandbox',
               '--package-path', str(root / package), '--scratch-path', str(scratch), *target_flags]
    subprocess.run([*command, '--product', product], env=environment,
                   check=True, stdout=subprocess.DEVNULL)
    output = subprocess.check_output([*command, '--show-bin-path'], env=environment, text=True).strip()
    return ['-module-cache-path', environment['CLANG_MODULE_CACHE_PATH'],
            '-I', str(Path(output) / 'Modules'), '-L', output, '-l' + product]
