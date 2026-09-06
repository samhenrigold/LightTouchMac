#!/usr/bin/env python3
"""Native app-side media pipeline: actual Swift AFC upload and import commands.

The test-only HTTP adapter replaces guestRun's transport with the QMP agent of
an isolated CLI guest. Production MediaSong, DeviceServices, IMobileDevice and
the DeviceTools music methods are compiled unchanged. No user app is launched.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
from types import SimpleNamespace

APP = Path(__file__).resolve().parents[1]
ROOT = APP.parent/'qemu-ios'
sys.path.insert(0,str(ROOT/'tests/ipod'))
import regress as r
os.environ['PATH'] = str(APP.parent/'qemu-ios-deps12/bin')+':'+os.environ['PATH']
out = Path(tempfile.mkdtemp(prefix='ltm-media-native-'))
files = str(APP.parent/'qemu-ios-files')
cfg = SimpleNamespace(out=str(out),files=files,base_nand=files+'/nand-agent-v3',
    nor=files+'/ios3/nor_7E18.bin',overlay=str(out/'overlay'),
    qemu=str(ROOT/'build-native14/qemu-build/qemu-system-arm'),
    usbmuxd=str(ROOT/'build-native14/build/usbmuxd/src/usbmuxd'),usbmuxd_ok=True,
    usb_port=r.free_port(1520,1539),mux_port=r.free_port(27400,27419),
    qmp_port=r.free_port(28200,28219),wifi=False,cpu=None,mem='128M',kernel_console=True)
text = (APP/'LightTouchMac/DeviceTools.swift').read_text()
methods = text[text.index('    // MARK: - Music import'):text.index('    // MARK: - Install')]
swift = r"""
import Foundation
struct InstalledApp: Sendable { let id, name, version: String }
enum DeviceToolsError: Error { case toolMissing(String), failed(String) }
nonisolated enum Bundled {
    static var frameworksDirectory: String? { CommandLine.arguments[5] }
    static func resolve(_ name: String, fallbacks: [String]) -> String? {
        fallbacks.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
struct DeviceTools: Sendable {
    let clientSocket: String
    let filesRoot: String
    private var services: DeviceServices { DeviceServices(clientSocket: clientSocket) }
""" + methods + r"""
    @discardableResult private func guestRun(_ command: String, stdinPath: String? = nil) async throws -> Data {
        let input = try stdinPath.map { try Data(contentsOf: URL(fileURLWithPath: $0)) } ?? Data()
        var request = URLRequest(url: URL(string: CommandLine.arguments[4])!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "command":command,"body":input.base64EncodedString(),
        ])
        let (data,_) = try await URLSession.shared.data(for: request)
        let result = try JSONSerialization.jsonObject(with: data) as! [String:Any]
        let output = Data(base64Encoded:result["body"] as! String)!
        guard result["status"] as? Int == 0 else {
            throw DeviceToolsError.failed(String(decoding:output,as:UTF8.self))
        }
        return output
    }
}
final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var last = 0.0
    func update(_ value: Double) {
        lock.withLock { precondition(value >= last && value <= 1); last = value }
    }
    func complete() -> Bool { lock.withLock { last == 1 } }
}
@main struct Check {
    static func main() async throws {
        let source = URL(fileURLWithPath:CommandLine.arguments[1])
        let song = try await MediaSong.prepare(source)
        defer { try? FileManager.default.removeItem(at: song.directory) }
        let device = DeviceTools(clientSocket:CommandLine.arguments[3],filesRoot:CommandLine.arguments[2])
        let progress = Progress()
        try await device.stageSong(song) { progress.update($0) }
        precondition(progress.complete())
        try await device.commitSong(song)
        try await device.commitSong(song) // Exact path reconciliation, no upload replay.
        let manifest = try JSONSerialization.data(withJSONObject:[
            "id":song.id,"filename":song.audio.lastPathComponent,"title":song.title,
        ])
        try manifest.write(to:URL(fileURLWithPath:CommandLine.arguments[6]))
        print("PASS: actual Swift preflight, AFC upload/progress, guest import commands and duplicate reconciliation")
    }
}
"""
driver = out/'driver.swift'
driver.write_text(swift)
executable = out/'driver'
subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor',
    '-module-cache-path',str(out/'modules'),
    str(APP/'LightTouchMac/MediaSong.swift'),str(APP/'LightTouchMac/DeviceServices.swift'),
    str(APP/'LightTouchMac/IMobileDevice.swift'),str(driver),'-o',str(executable)],check=True)
source = out/"Song 'quoted' $title — été.m4a"
shutil.copyfile(ROOT/'contrib/it-harness/build/Payload/Harness.app/aac.m4a',source)
p = r.Procs()
d = r.Device(cfg,p,'device')
server = None
r.START = time.time()
print('OUTPUT',out,flush=True)
try:
    d.start()
    ok, detail, _ = d.wait_for_home(240)
    assert ok,detail
    deadline = time.monotonic()+90
    while not r.itqmp.agent_alive(d.qmp):
        assert time.monotonic()<deadline
        time.sleep(1)
    udid, detail = r.wait_for_device(cfg,timeout=120)
    assert udid,detail
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            import base64
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            status, output = r.itqmp.agent(d.qmp,'exec',body['command'],base64.b64decode(body['body']))
            result = json.dumps(dict(status=status,body=base64.b64encode(output).decode())).encode()
            self.send_response(200)
            self.send_header('Content-Length',str(len(result)))
            self.end_headers()
            self.wfile.write(result)
        def log_message(self,*args):
            pass
    server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    manifest = out/'manifest.json'
    frameworks = ROOT/'build-native14/Light Touch-current.app/Contents/Frameworks'
    subprocess.run([str(executable),str(source),files,'127.0.0.1:'+str(cfg.mux_port),
        'http://127.0.0.1:'+str(server.server_port),str(frameworks),str(manifest)],check=True,timeout=180)
    server.shutdown()
    server.server_close()
    server = None
    imported = json.loads(manifest.read_text())
    remote = '/var/mobile/Media/LightTouch/'+imported['id']+'/'+imported['filename']
    status, data = r.itqmp.agent(d.qmp,'get',remote)
    assert status == 0 and data == source.read_bytes(), 'AFC bytes changed'
    status, data = r.itqmp.agent(d.qmp,'get',
        '/var/mobile/Media/iTunes_Control/iTunes/iTunes Library.itlp/Library.itdb')
    assert status == 0
    database = out/'Library.itdb'
    database.write_bytes(data)
    with sqlite3.connect(database) as db:
        rows = db.execute('SELECT title FROM item WHERE is_song=1').fetchall()
    assert len(rows) == 1 and unicodedata.normalize('NFC',rows[0][0]) == unicodedata.normalize('NFC',source.stem), rows
    control = r.prepare_app_control(cfg,p,d,r.Result('media control'))
    ok, detail = r.unlock(cfg,control,d)
    assert ok,detail
    assert r.itqmp.agent(d.qmp,'launch','com.apple.mobileipod')[0] == 0
    deadline = time.monotonic()+45
    while True:
        status, front = r.itqmp.agent(d.qmp,'frontmost')
        if status == 0 and front.startswith(b'com.apple.mobileipod'):
            break
        assert time.monotonic()<deadline,front
        time.sleep(1)
    time.sleep(2)
    d.qmp.tap(160,455)
    time.sleep(2)
    r.to_png(d.qmp.shot(str(out/'songs.ppm')),str(out/'songs.png'))
    assert d.powerdown(), 'guest shutdown not confirmed'
    print('PASS: byte-exact native AFC transfer, Unicode/quoted metadata, single library row and guest shutdown',flush=True)
finally:
    if server:
        server.shutdown()
        server.server_close()
    if d.qmp:
        d.qmp.close()
    p.stop_all()
