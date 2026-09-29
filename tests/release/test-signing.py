#!/usr/bin/env python3
"""Launch a signed helper with a bundled dylib using production signing policy."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def run(*args, env=None):
    return subprocess.run(list(map(str, args)), env=env, check=True,
                          capture_output=True, text=True, timeout=60)


def details(path):
    result = run('codesign', '-dvv', path)
    return result.stdout + result.stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sign-id', default='-', help='Optional real Developer ID signing identity')
    parser.add_argument('--package-script', type=Path, default=Path(__file__).resolve().parents[2] / 'scripts/package.sh')
    args = parser.parse_args()
    package = args.package_script.read_text()
    # Execute the function used by the packaging loop, without running the
    # product build or accessing firmware, devices, daemons or user state.
    function = re.search(r'^sign_nested_code\(\) \{\n.*?^\}', package, re.M | re.S)
    assert function, 'missing production nested-code signing function'
    function = function.group()
    loop = package[package.index('# Sign inside-out:'):package.index('codesign --verify --deep --strict')]
    assert 'sign_nested_code "$f"' in loop
    assert 'codesign -f -o runtime -s "$SIGN_ID" "$f"' not in loop

    with tempfile.TemporaryDirectory(prefix='lighttouch-signing-') as directory:
        root = Path(directory)
        sign = root / 'sign.sh'
        sign.write_text('set -euo pipefail\n' + function + '\nsign_nested_code "$1"\n')
        env = os.environ.copy()
        env['SIGN_ID'] = args.sign_id

        # Assert the Developer ID branch requests runtime validation with the
        # same explicit identity for both files, without broad helper exceptions.
        fake = root / 'fake-bin'
        fake.mkdir()
        recorder = fake / 'codesign'
        recorder.write_text('#!/usr/bin/env python3\nimport json, os, sys\n'
                            'with open(os.environ["SIGN_ARGUMENTS"], "a") as f:\n'
                            '    f.write(json.dumps(sys.argv[1:]) + "\\n")\n')
        recorder.chmod(0o755)
        recorded = root / 'sign-arguments.jsonl'
        policy_env = {**env, 'PATH': str(fake) + os.pathsep + env['PATH'],
                      'SIGN_ID': 'Developer ID Application: Test Team (TESTTEAMID)',
                      'SIGN_ARGUMENTS': str(recorded)}
        for name in ('helper', 'libfixture.dylib'):
            run('bash', sign, root / name, env=policy_env)
        invocations = list(map(json.loads, recorded.read_text().splitlines()))
        assert len(invocations) == 2
        for invocation, name in zip(invocations, ('helper', 'libfixture.dylib')):
            assert invocation == ['-f', '-o', 'runtime', '-s', policy_env['SIGN_ID'], str(root / name)]

        app = root / 'Test.app'
        frameworks, macos = app / 'Contents/Frameworks', app / 'Contents/MacOS'
        frameworks.mkdir(parents=True)
        macos.mkdir()
        library, helper = frameworks / 'libfixture.dylib', macos / 'fixture-helper'
        lib_source, helper_source = root / 'library.c', root / 'helper.c'
        lib_source.write_text('int fixture_value(void) { return 42; }\n')
        helper_source.write_text('#include <stdio.h>\nextern int fixture_value(void);\n'
                                 'int main(void) { if (fixture_value() != 42) return 1;\n'
                                 'puts("bundled dylib loaded"); return 0; }\n')
        run('cc', '-arch', 'arm64', '-mmacosx-version-min=14.0', '-dynamiclib',
            lib_source, '-install_name', '@rpath/libfixture.dylib', '-o', library)
        run('cc', '-arch', 'arm64', '-mmacosx-version-min=14.0', helper_source, library,
            '-Wl,-rpath,@executable_path/../Frameworks', '-o', helper)
        # Reproduce the previous input signature, then ensure the production
        # policy replaces its flags instead of inheriting adhoc+runtime.
        for path in (library, helper):
            run('codesign', '-f', '-o', 'runtime', '-s', '-', path)
            run('bash', sign, path, env=env)
            run('codesign', '--verify', '--strict', path)
        helper_details, library_details = details(helper), details(library)
        if args.sign_id == '-':
            assert 'Signature=adhoc' in helper_details
            for value in (helper_details, library_details):
                flags = re.search(r'flags=0x([0-9a-fA-F]+)', value)
                assert flags and int(flags[1], 16) & 0x10000 == 0, value
        else:
            teams = [re.search(r'^TeamIdentifier=(.+)$', value, re.M)
                     for value in (helper_details, library_details)]
            assert all(teams) and teams[0][1] == teams[1][1] != 'not set'
            assert 'runtime' in helper_details
            entitlements = run('codesign', '-d', '--entitlements', ':-', helper)
            assert 'disable-library-validation' not in entitlements.stdout + entitlements.stderr

        relocated = root / 'Relocated with spaces.app'
        shutil.move(app, relocated)
        executable = relocated / 'Contents/MacOS/fixture-helper'
        assert run(executable).stdout.strip() == 'bundled dylib loaded'
    print('PASS: actual signed helper launch and dylib relocation; Developer ID same-identity runtime policy')


if __name__ == '__main__':
    main()
