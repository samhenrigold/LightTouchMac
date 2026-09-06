#!/usr/bin/env python3
"""Exercise production package copy functions without rebuilding device media."""
from pathlib import Path
import subprocess, tempfile, os
root = Path(__file__).resolve().parents[1]
script = (root / 'scripts/package.sh').read_text()
copy_lib = script[script.index('copy_with_deps() {'):script.index('echo "embedding dylib')]
copy_tool = script[script.index('copy_tool() {'):script.index('echo "embedding compatible tools')]
with tempfile.TemporaryDirectory(prefix='ltm-package-layout-') as tmp:
    work = Path(tmp)
    app = work/'Fixture.app'
    for name in ['Frameworks', 'MacOS', 'Resources/tools']:
        (app/'Contents'/name).mkdir(parents=True, exist_ok=True)
    (work/'check.py').write_text('pass\n')
    (work/'libfixture.1.dylib').write_bytes(b'dylib fixture')
    (work/'libfixture.dylib').symlink_to('libfixture.1.dylib')
    (work/'guest').write_bytes(b'guest payload')
    (app/'Contents/Resources/tools/echo').write_bytes(b'stale native tool')
    env = os.environ | {'APP':str(app), 'FRAMEWORKS':str(app/'Contents/Frameworks'),
        'TOOLS':str(app/'Contents/Resources/tools'), 'CHECK':str(work/'check.py'),
        'MINOS':'14.0', 'WORK':str(work)}
    commands = r'''set -eu
COPIED=" "
HOST_TOOLS=()
install_name_tool() { :; }
''' + copy_lib + copy_tool + r'''
copy_with_deps "$WORK/libfixture.dylib"
copy_with_deps "$WORK/libfixture.1.dylib"
copy_tool /bin/echo
copy_tool "$WORK/guest" guest
[ -f "$FRAMEWORKS/libfixture.1.dylib" ]
[ ! -e "$FRAMEWORKS/libfixture.dylib" ]
[ -x "$APP/Contents/MacOS/echo" ]
[ ! -e "$TOOLS/echo" ]
[ -f "$TOOLS/guest" ]
[ "${HOST_TOOLS[0]}" = "$APP/Contents/MacOS/echo" ]
'''
    subprocess.run(['bash','-c',commands], env=env, check=True)
print('PASS: canonical library copies, native helper placement, stale copy removal, guest resources')

# Exercise the actual automatic-discovery branch against both product names.
a=script.index('if [ -z "$APP" ]; then')
b=script.index('\n[ -d "$APP" ]',a)
with tempfile.TemporaryDirectory(prefix='ltm-package-discovery-') as tmp:
    tree=Path(tmp)
    for product in ['Light Touch.app', 'LightTouchMac.app']:
        release=tree/'LightTouchMac-fixture/Build/Products/Release'/product
        debug=tree/'LightTouchMac-fixture/Build/Products/Debug'/product
        release.mkdir(parents=True);debug.mkdir(parents=True)
        discovery=script[a:b].replace('$HOME/Library/Developer/Xcode/DerivedData', str(tree))
        selected=subprocess.check_output(['bash','-c','APP=""\n'+discovery+'\nprintf "%s" "$APP"'], text=True)
        assert selected==str(release), selected
        release.rmdir();debug.rmdir()
print('PASS: current and legacy Release bundle discovery excludes Debug products')
