#!/usr/bin/env python3
"""Exercise the actual plist edit and SSH shell with isolated fake transport."""
from pathlib import Path
import json, os, signal, subprocess, tempfile, time
root = Path(__file__).resolve().parents[1]
source = (root / 'LightTouchMac/DeviceTools.swift').read_text()
a = source.index('    static func mediaLaunchConfiguration(')
b = source.index("    /// Push the guest's dirty buffers", a)
method = source[a:b]
a = source.index('        let script = """', source.index('    private func guestRun'))
b = source.index('        var platform = PlatformOptions()', a)
script = source[a:b]
with tempfile.TemporaryDirectory(prefix='ltm-media-') as work:
    work = Path(work)
    swift = work / 'check.swift'
    swift.write_text(r'''import Foundation
enum DeviceToolsError: Error { case failed(String) }
enum Check {
''' + method + r'''}
let job: [String: Any] = ["Label": "com.apple.SpringBoard", "ProgramArguments": ["/System/Library/CoreServices/SpringBoard.app/SpringBoard"], "KeepAlive": true, "EnvironmentVariables": ["CA_ENABLE_OGL": "0", "OTHER": "untouched", "CA_ENABLE_MBX2D": "0"]]
for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
 let original = try PropertyListSerialization.data(fromPropertyList: job, format: format, options: 0)
 let updated = try Check.mediaLaunchConfiguration(original)!
 var actualFormat = PropertyListSerialization.PropertyListFormat.xml
 let decoded = try PropertyListSerialization.propertyList(from: updated, format: &actualFormat) as! [String: Any]
 precondition(actualFormat == format)
 var expected = job
 expected["EnvironmentVariables"] = ["CA_ENABLE_OGL": "1", "LK_ENABLE_OGL": "1", "OTHER": "untouched", "CA_ENABLE_MBX2D": "0"]
 precondition(NSDictionary(dictionary: decoded).isEqual(to: expected))
 let repeated = try Check.mediaLaunchConfiguration(updated)
 precondition(repeated == nil)
}
for invalid: Any in [["Label": "wrong"], ["Label": "com.apple.SpringBoard", "EnvironmentVariables": "bad"], ["array"]] {
 let data = try PropertyListSerialization.data(fromPropertyList: invalid, format: .binary, options: 0)
 do { _ = try Check.mediaLaunchConfiguration(data); fatalError("accepted invalid job") } catch {}
}
do { _ = try Check.mediaLaunchConfiguration(Data("broken".utf8)); fatalError("accepted corrupt plist") } catch {}
''' + script + r'''try Data(script.utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
''')
    executable = work / 'check'
    shell = work / 'ssh.sh'
    subprocess.run(['swiftc', '-module-cache-path', '/tmp/ltm-module-cache', str(swift), '-o', str(executable)], check=True)
    subprocess.run([str(executable), str(shell)], check=True)
    proxy = work / 'proxy with spaces'
    proxy.write_text('#!/bin/sh\nprintf "%s" "$$" > "$PROXY_PID"\nexec /bin/sleep 60\n'.replace('\\n', '\n'))
    proxy.chmod(0o755)
    ssh = work / 'ssh'
    ssh.write_text('#!/usr/bin/python3\n' + r"""
import os, sys, subprocess, json, time
from pathlib import Path
Path(os.environ['ASK_PATH']).write_text(os.environ['SSH_ASKPASS'])
if os.environ.get('HANG'):
    time.sleep(60)
else:
    print(json.dumps(dict(args=sys.argv[1:], password=subprocess.check_output([os.environ['SSH_ASKPASS']]).decode(), data=list(sys.stdin.buffer.read()))))
""".replace('\\n', '\n'))
    ssh.chmod(0o755)
    payload = work / "input with ' and $ spaces"
    payload.write_bytes(bytes([0, 255, 10, 39]))
    password = "literal ' $() `backtick` \\ value"
    command = "printf %s 'com.example.app'; printf '%s' \"$HOME\""
    env = dict(os.environ, PATH=str(work) + ':/usr/bin:/bin', PROXY_PID=str(work/'proxy.pid'), ASK_PATH=str(work/'ask.path'))
    args = ['/bin/bash', str(shell), str(proxy), '29299', password, command, str(payload)]
    result = subprocess.run(args, env=env, capture_output=True, check=True)
    decoded = json.loads(result.stdout)
    assert decoded['password'] == password
    assert decoded['args'][-1] == command
    assert decoded['data'] == list(payload.read_bytes())
    assert not Path((work/'ask.path').read_text()).exists()
    (work/'ask.path').unlink()
    proc = subprocess.Popen(args, env=dict(env, HANG='1'), start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 10
        while not (work/'ask.path').exists():
            assert proc.poll() is None and time.monotonic() < deadline
            time.sleep(.05)
        os.killpg(proc.pid, signal.SIGTERM)
        proc.communicate(timeout=5)
        assert proc.returncode != 0
        assert not Path((work/'ask.path').read_text()).exists()
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
print('PASS: XML/binary media upgrade preserves settings, is idempotent, rejects corrupt jobs; SSH preserves binary input/quoting and cleans up on cancellation')
