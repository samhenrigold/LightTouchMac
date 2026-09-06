#!/usr/bin/env python3
"""Native app-side media pipeline: actual Swift AFC upload and import commands.

The test-only HTTP adapter replaces guestRun's transport with the QMP agent of
an isolated CLI guest. Production MediaSong, DeviceServices, IMobileDevice and
the DeviceTools music methods are compiled unchanged. No user app is launched.
"""
import argparse
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

parser = argparse.ArgumentParser(description=__doc__)
mode = parser.add_mutually_exclusive_group()
mode.add_argument('--photo',action='store_true')
mode.add_argument('--aac',action='store_true',help='convert raw AAC, import it and verify native Music playback')
args = parser.parse_args()
APP = Path(__file__).resolve().parents[1]
ROOT = APP.parent/'qemu-ios'
sys.path.insert(0,str(ROOT/'tests/ipod'))
import regress as r
os.environ['PATH'] = str(APP.parent/'qemu-ios-deps12/bin')+':'+os.environ['PATH']
for setting in ['IT_AMC_DECODE','IT_MPVD_DECODE','IT_H264_DECODE','IT_SCALER_DECODE','IT_LCD_PLANES']:
    os.environ[setting] = '1'
out = Path(tempfile.mkdtemp(prefix='ltm-media-native-'))
files = str(APP.parent/'qemu-ios-files')
cfg = SimpleNamespace(out=str(out),files=files,base_nand=files+'/nand-agent-v4',
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
        let media = try await PreparedMedia.prepare(source)
        defer { try? FileManager.default.removeItem(at: media.directory) }
        let id: String
        let file: URL
        switch media {
        case .song(let song): id = song.id; file = song.audio
        case .photo(let photo): id = photo.id; file = photo.image
        }
        let prepared = URL(fileURLWithPath:CommandLine.arguments[6]).deletingLastPathComponent()
            .appendingPathComponent("prepared." + file.pathExtension)
        try FileManager.default.copyItem(at:file,to:prepared)
        let device = DeviceTools(clientSocket:CommandLine.arguments[3],filesRoot:CommandLine.arguments[2])
        let progress = Progress()
        try await device.stageMedia(media) { progress.update($0) }
        precondition(progress.complete())
        try await device.commitMedia(media)
        try await device.commitMedia(media) // Exact path reconciliation, no upload replay.
        let manifest = try JSONSerialization.data(withJSONObject:[
            "id":id,"filename":file.lastPathComponent,"title":media.title,
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
    str(APP/'LightTouchMac/IMobileDevice.swift'),str(APP/'LightTouchMac/MediaPhoto.swift'),
    str(APP/'LightTouchMac/PreparedMedia.swift'),str(driver),'-o',str(executable)],check=True)
if args.photo:
    from PIL import Image,ImageDraw
    source = out/"Photo 'quoted' $title — été.png"
    image = Image.new('RGBA',(4096,3072),(0,0,0,0))
    draw = ImageDraw.Draw(image)
    draw.rectangle((0,0,2047,1535),fill=(220,30,30,255))
    draw.rectangle((2048,0,4095,1535),fill=(30,210,30,255))
    draw.rectangle((0,1536,2047,3071),fill=(30,30,220,255))
    image.save(source)
elif args.aac:
    source = out/"Song 'quoted' $title — été.aac"
    subprocess.run(['ffmpeg','-v','error','-i',str(ROOT/'contrib/it-harness/build/Payload/Harness.app/aac.m4a'),
                    '-c:a','copy','-f','adts',str(source)],check=True)
else:
    source = out/"Song 'quoted' $title — été.m4a"
    shutil.copyfile(ROOT/'contrib/it-harness/build/Payload/Harness.app/aac.m4a',source)
p = r.Procs()
d = r.Device(cfg,p,'device')
server = None
r.START = time.time()
print('OUTPUT',out,flush=True)
try:
    d.start(audio_wav=str(out/"music.wav") if args.aac else None)
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
    if args.photo:
        status, receipt = r.itqmp.agent(d.qmp,'get','/var/mobile/Media/LightTouch/'+imported['id']+'/.photo-receipt')
        assert status == 0 and receipt == b'done\n',receipt
        status, listing = r.itqmp.agent(d.qmp,'exec','find /var/mobile/Media/DCIM -type f')
        assert status == 0
        originals = [path for path in listing.decode().splitlines() if path.endswith('.JPG')]
        assert len(originals) == 1,originals
        status, data = r.itqmp.agent(d.qmp,'get',originals[0])
        assert status == 0
        (out/'saved.jpg').write_bytes(data)
        with Image.open(out/'saved.jpg') as saved:
            assert saved.size == (2048,1536),saved.size
            for point,expected in [((512,384),(220,30,30)),((1536,384),(30,210,30)),
                                   ((512,1152),(30,30,220)),((1536,1152),(255,255,255))]:
                actual = saved.convert('RGB').getpixel(point)
                assert all(abs(a-b)<20 for a,b in zip(actual,expected)),(point,actual)
        bundle = 'com.apple.mobileslideshow'
    else:
        status, data = r.itqmp.agent(d.qmp,'get',remote)
        assert status == 0 and data == (out/'prepared.m4a').read_bytes(), 'AFC bytes changed'
        if not args.aac: assert data == source.read_bytes(), 'immutable copy changed'
        status, data = r.itqmp.agent(d.qmp,'get',
            '/var/mobile/Media/iTunes_Control/iTunes/iTunes Library.itlp/Library.itdb')
        assert status == 0
        database = out/'Library.itdb'
        database.write_bytes(data)
        with sqlite3.connect(database) as db:
            rows = db.execute('SELECT title FROM item WHERE is_song=1').fetchall()
        assert len(rows) == 1 and unicodedata.normalize('NFC',rows[0][0]) == unicodedata.normalize('NFC',source.stem), rows
        bundle = 'com.apple.mobileipod'
    control = r.prepare_app_control(cfg,p,d,r.Result('media control'))
    ok, detail = r.unlock(cfg,control,d)
    assert ok,detail
    assert r.itqmp.agent(d.qmp,'launch',bundle)[0] == 0
    deadline = time.monotonic()+45
    while True:
        status, front = r.itqmp.agent(d.qmp,'frontmost')
        if status == 0 and front.startswith(bundle.encode()):
            break
        assert time.monotonic()<deadline,front
        time.sleep(1)
    time.sleep(2)
    if not args.photo:
        d.qmp.tap(160,455)
    time.sleep(2)
    r.to_png(d.qmp.shot(str(out/'library.ppm')),str(out/'library.png'))
    if args.aac:
        for _ in range(16): r.itqmp.button(d.qmp,'volup',hold_ms=100)
        print('AFTER VOLUME',r.itqmp.agent(d.qmp,'frontmost'),flush=True)
        status, reports = r.itqmp.agent(d.qmp,'exec','find /var/mobile/Library/Logs/CrashReporter -type f')
        print('CRASH REPORTS',status,reports,flush=True)
        if status == 0:
            for number,path in enumerate(reports.decode().splitlines()):
                if 'MobileMusicPlayer' in path or 'LowMemory' in path:
                    status,data = r.itqmp.agent(d.qmp,'get',path)
                    if status == 0: (out/('crash-'+str(number)+'.txt')).write_bytes(data)
        assert r.itqmp.agent(d.qmp,'launch',bundle)[0] == 0
        time.sleep(3)
        d.qmp.tap(160,455)
        time.sleep(2)
        # A one-song library has no Shuffle row; the song is the first row.
        d.qmp.tap(130,88)
        time.sleep(2)
        print('PLAYING',r.itqmp.agent(d.qmp,'frontmost'),flush=True)
        time.sleep(6)
        r.to_png(d.qmp.shot(str(out/'playing.ppm')),str(out/'playing.png'))
    assert d.powerdown(), 'guest shutdown not confirmed'
    if args.aac:
        audio = r.Result('converted AAC playback')
        assert r.verify_audio(str(out/'music.wav'),audio),audio.detail
        print('PASS: converted AAC played by native Music: '+audio.detail,flush=True)
    print('PASS: native media preparation/upload, single library item, duplicate reconciliation and guest shutdown',flush=True)
finally:
    if server:
        server.shutdown()
        server.server_close()
    if d.qmp:
        d.qmp.close()
    p.stop_all()
