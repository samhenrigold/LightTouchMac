#!/usr/bin/env python3
"""Native app-side media pipeline: actual Swift AFC upload and import commands.

The test-only HTTP adapter stands in for the helper's DeviceLink: it carries the
app's own agent wire (GuestAgent, typed ops or a v1 agent's exec) to the QMP agent
of an isolated CLI guest. Production MediaSong, DeviceServices, IMobileDevice,
GuestServices and MediaImport are compiled unchanged. No user
app is launched.
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import device_runtime
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
DEVICE_PROFILE = str(Path(__file__).resolve().parents[2] / 'LightTouchMac/Device/DeviceProfile.swift')

parser = argparse.ArgumentParser(description=__doc__)
mode = parser.add_mutually_exclusive_group()
mode.add_argument('--photo',action='store_true')
mode.add_argument('--video',action='store_true',help='convert and import a movie into the Videos library')
mode.add_argument('--aac',action='store_true',help='convert raw AAC, import it and verify native Music playback')
mode.add_argument('--tagged-aac',action='store_true',help='convert ID3-tagged ADTS AAC and verify full tags/art over AFC')
mode.add_argument('--tagged',action='store_true',help='import a fully tagged song with embedded art; read the library and ArtworkCache back over AFC')
parser.add_argument('--recording',action='store_true',help='record embedded QEMU video and guest audio across a pause (requires --aac)')
parser.add_argument('--files', type=Path, default=Path(__file__).resolve().parents[3] / 'qemu-ios-files',
                    help='firmware assets (explicit when running from a worktree)')
parser.add_argument('--device', type=Path, help='isolated generated N72 base to test; copied NOR and fresh overlay')
parser.add_argument('--guest-package',type=Path,help='guest package offered to QEMU at boot (separate from flat upload tools)')
parser.add_argument('--guest-tools' ,type=Path,help='freshly built guest payloads to use instead of checkout binaries')
args = parser.parse_args()
args.tagged = args.tagged or args.tagged_aac
if args.recording and not args.aac: parser.error('--recording requires --aac')
APP = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(APP/'scripts'))
import swift_subprocess
import host_service
import sources  # the pinned checkouts (build-support/sources.json)
ROOT = sources.path('qemu-ios')
sys.path.insert(0,str(ROOT/'tests/ipod'))
import regress as r
os.environ['PATH'] = os.environ.get('LTM_STATIC_DEPS',str(APP.parent/'qemu-ios-deps12'))+'/bin'+':'+os.environ['PATH']
for setting in ['IT_AMC_DECODE','IT_MPVD_DECODE','IT_H264_DECODE','IT_SCALER_DECODE','IT_LCD_PLANES']:
    os.environ[setting] = '1'
out = Path(tempfile.mkdtemp(prefix='ltm-media-native-'))
files = str(args.files.resolve())
cfg = SimpleNamespace(out=str(out),files=files,base_nand=files+'/nand-current',
    nor=files+'/ios3/nor_7E18.bin',overlay=str(out/'overlay'),
    qemu=str(sources.qemu_build()/'qemu-system-arm'),
    usbmuxd=str(sources.path('usbmuxd')/'src/usbmuxd'),usbmuxd_ok=True,
    usb_port=r.free_port(1520,1539),mux_port=r.free_port(27400,27419),
    qmp_port=r.free_port(28200,28219),wifi=False,cpu=None,mem='128M',kernel_console=True,board='n72ap',
    home_lit_min=r.HOME_LIT_MIN,device_version=None,device_machine={})
if args.device:
    base = args.device.resolve()
    shutil.copyfile(base / 'nor.bin', out / 'nor.bin')
    cfg.device = str(base)
    cfg.base_nand = str(base / 'nand')
    cfg.nor = str(out / 'nor.bin')
    cfg.direct_iboot = str(base / 'iBoot.bin')
    cfg.gid_blobs = str(base / 'gid-blobs.bin')
    cfg.device_machine = json.loads((base / 'device.lock.json').read_text()).get('machine', {})
if args.guest_package:
    cfg.guest_package = str(args.guest_package.resolve())
swift = r"""
import Foundation
nonisolated func logEvent(_ message: String) { NSLog("%@", message) }
nonisolated enum Bundled {
    static var frameworksDirectory: String? { CommandLine.arguments[5] }
    static var filesRoot: String { CommandLine.arguments[2] }
    static func resolve(_ name: String, fallbacks: [String]) -> String? {
        if CommandLine.arguments.count > 7 {
            let candidate = URL(fileURLWithPath: CommandLine.arguments[7]).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return fallbacks.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
/// DeviceLink's agent surface, relayed over HTTP to the guest's QMP agent.
nonisolated struct SharedStatus { var agentStatus: Int }
enum DeviceLinkError: Error { case timedOut, closed(String) }
nonisolated final class DeviceLink: Sendable {
    var status: SharedStatus? { SharedStatus(agentStatus: 1) }
    func send(_ command: LinkCommand) {}
    func request(_ request: LinkRequest, timeout: TimeInterval = 10) async throws -> LinkReply {
        guard case let .agent(wire, _) = request else { fatalError() }
        var http = URLRequest(url: URL(string: CommandLine.arguments[4])!)
        http.httpMethod = "POST"
        http.timeoutInterval = 90
        http.httpBody = Data(wire.utf8)
        let (data, _) = try await URLSession.shared.data(for: http)
        return .agent(String(decoding: data, as: UTF8.self))
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
        func prepare() async throws -> PreparedMedia {
            if MediaVideo.extensions.contains(source.pathExtension.lowercased()) {
                return .video(try await MediaVideo.prepare(source, cacheDirectory: source.deletingLastPathComponent().appendingPathComponent("video-cache"), profile: .iPodTouch2G))
            }
            return try await PreparedMedia.prepare(source, profile: .iPodTouch2G)
        }
        let media = try await prepare()
        defer { try? FileManager.default.removeItem(at: media.directory) }
        let id: String
        let file: URL
        switch media {
        case .song(let song): id = song.id; file = song.audio
        case .photo(let photo): id = photo.id; file = photo.image
        case .video(let video): id = video.id; file = video.video
        }
        let prepared = URL(fileURLWithPath:CommandLine.arguments[6]).deletingLastPathComponent()
            .appendingPathComponent("prepared." + file.pathExtension)
        try FileManager.default.copyItem(at:file,to:prepared)
        let device = MediaImport(services: DeviceServices(clientSocket: CommandLine.arguments[3]),
                                 guest: GuestServices(agent: GuestAgent(link: DeviceLink(), cache: GuestAgentCache())))
        let progress = Progress()
        print("STAGING", id, file.lastPathComponent)
        try await device.stage(media) { progress.update($0) }
        print("STAGED")
        precondition(progress.complete())
        try await device.commit(media)
        print("COMMITTED")
        try await device.commit(media) // Reconcile an uncertain reply.
        let repeated = try await prepare()
        defer { try? FileManager.default.removeItem(at: repeated.directory) }
        let secondID: String
        switch repeated {
        case .song(let song): secondID = song.id
        case .photo(let photo): secondID = photo.id
        case .video(let video): secondID = video.id
        }
        precondition(secondID == id)
        try await device.stage(repeated) { _ in }
        try await device.commit(repeated)
        if case .song = media {
        // A mismatched candidate must never truncate the already imported file.
        let badDirectory = media.directory.appendingPathComponent("mismatch")
        try FileManager.default.createDirectory(at: badDirectory, withIntermediateDirectories: false)
        let badFile = badDirectory.appendingPathComponent(file.lastPathComponent)
        var badBytes = try Data(contentsOf: file); badBytes[badBytes.count - 1] ^= 1
        try badBytes.write(to: badFile)
        let bad: PreparedMedia
        switch media {
        case .song(let song): bad = .song(MediaSong(id: song.id, directory: badDirectory, audio: badFile, metadata: song.metadata, title: song.title))
        case .photo(let photo): bad = .photo(MediaPhoto(id: photo.id, directory: badDirectory, image: badFile, title: photo.title))
        case .video(let video): bad = .video(MediaVideo(id: video.id, directory: badDirectory, video: badFile, metadata: video.metadata, title: video.title))
        }
        do { try await device.stage(bad) { _ in }; fatalError("overwrote an existing media file") }
        catch {}
        try await device.stage(media) { _ in } // Original bytes still match.
        }
        // A late startup sweep sees both abandoned and current-session uploads.
        let services = DeviceServices(clientSocket: CommandLine.arguments[3])
        let dummy = media.directory.appendingPathComponent("cleanup-check.ipa")
        try Data("owned upload".utf8).write(to: dummy)
        let owned = try await services.stage(dummy) { _ in }
        let directory = "/var/mobile/Media/LightTouch/" + id
        let orphan = directory + "/image.jpg.upload-" + UUID().uuidString
        let keep = directory + "/image.jpg.upload-not-a-valid-id"
        let agent = device.guest.agent
        for (path, text) in [("/var/mobile/Media/PublicStaging/old-test.ipa", "old"), (orphan, "old"), (keep, "keep")] {
            try await agent.put(path, mode: 0o644, Data(text.utf8))
        }
        await services.sweepStaging()
        let ownedKept = try await agent.get("/var/mobile/Media/" + owned) != nil
        let oldGone = try await agent.get("/var/mobile/Media/PublicStaging/old-test.ipa") == nil
        let orphanGone = try await agent.get(orphan) == nil
        let keepKept = try await agent.get(keep) != nil
        precondition(ownedKept && oldGone && orphanGone && keepKept, "staging sweep")
        await services.removeStaged(owned)
        let manifest = try JSONSerialization.data(withJSONObject:[
            "id":id,"filename":file.lastPathComponent,"title":media.title,
        ])
        try manifest.write(to:URL(fileURLWithPath:CommandLine.arguments[6]))
        // The library and the purchased-item ArtworkCache, over AFC with the Files browser's code.
        if let readback = ProcessInfo.processInfo.environment["LTM_AFC_READBACK"] {
            for folder in ["iTunes_Control/iTunes/iTunes Library.itlp", "Purchases/MobileArtworkDB"] {
                for file in try await services.files(in: folder) where file.isRegular {
                    try await services.download(file, to: URL(fileURLWithPath: readback).appendingPathComponent(file.name)) { _ in }
                }
            }
        }
        await services.stopWorker()

        print("PASS: actual Swift preflight, AFC upload/progress, guest import commands and duplicate reconciliation")
    }
}
"""
driver = out/'driver.swift'
driver.write_text(swift)
executable = out/'driver'
subprocess.run(['xcrun','swiftc', *device_runtime.swift_flags(Path(__file__).resolve().parents[2]), *swift_subprocess.swift_flags(APP), *[APP / f'LightTouchMac/Services/{name}.swift' for name in ['HostServiceTypes','HostServiceProtocol','HostServiceResources','HostServiceWorkers','MediaStaging']], DEVICE_PROFILE,'-swift-version','5','-default-isolation','MainActor',
    '-module-cache-path',str(out/'modules'),
    str(APP/'LightTouchMac/Features/MediaIdentity.swift'),str(APP/'LightTouchMac/Features/MediaSong.swift'),str(APP/'LightTouchMac/Services/DeviceServices.swift'),str(APP/'LightTouchMac/Services/AFC.swift'),str(APP/'LightTouchMac/Transport/DeviceExecution.swift'),
    str(APP/'LightTouchMac/Transport/IMobileDevice.swift'),str(APP/'LightTouchMac/Features/MediaPhoto.swift'),
    str(APP/'LightTouchMac/Features/MediaVideo.swift'),str(APP/'LightTouchMac/Features/PreparedMedia.swift'),
    str(APP/'LightTouchMac/Guest/GuestServices.swift'),str(APP/'LightTouchMac/Features/MediaImport.swift'),str(APP/'LightTouchMac/Guest/GuestAgent.swift'),str(driver),'-o',str(executable)],check=True)
host_service.build_worker(APP, out / "LightTouchServices", swift_subprocess.swift_flags(APP))
if args.photo:
    from PIL import Image,ImageDraw
    source = out/"Photo 'quoted' $title — été.png"
    image = Image.new('RGBA',(4096,3072),(0,0,0,0))
    draw = ImageDraw.Draw(image)
    draw.rectangle((0,0,2047,1535),fill=(220,30,30,255))
    draw.rectangle((2048,0,4095,1535),fill=(30,210,30,255))
    draw.rectangle((0,1536,2047,3071),fill=(30,30,220,255))
    image.save(source)
elif args.video:
    source = out/"Movie 'quoted' $title — été.mp4"
    shutil.copyfile(ROOT/'contrib/it-harness/build/Payload/Harness.app/h264.mp4',source)
elif args.tagged:
    from PIL import Image,ImageDraw
    import math, struct, wave
    QUADRANTS = [((0.25,0.25),(200,40,40)),((0.75,0.25),(40,180,60)),((0.25,0.75),(40,60,200)),((0.75,0.75),(240,220,30))]
    cover = Image.new('RGB',(1000,1000))
    draw = ImageDraw.Draw(cover)
    for (x,y),colour in QUADRANTS:
        draw.rectangle((int((x-0.25)*1000),int((y-0.25)*1000),int((x+0.25)*1000)-1,int((y+0.25)*1000)-1),fill=colour)
    cover.save(out/'cover.png')
    with wave.open(str(out/'tone.wav'),'wb') as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100)
        w.writeframes(b''.join(struct.pack('<hh',v,v) for v in (int(8000*math.sin(2*math.pi*440*i/44100)) for i in range(44100*6))))
    subprocess.run(['afconvert','-f','m4af','-d','aac','-b','128000',str(out/'tone.wav'),str(out/'plain.m4a')],check=True)
    source = out/'Tagged Song.m4a'
    subprocess.run(['ffmpeg','-v','error','-i',str(out/'plain.m4a'),'-i',str(out/'cover.png'),'-map','0','-map','1','-c','copy',
        '-disposition:v','attached_pic','-metadata','title=Tagged Tïtle','-metadata','artist=Track Artist',
        '-metadata','album=The Album','-metadata','album_artist=Album Artist','-metadata','composer=Some Composer',
        '-metadata','genre=Synthpop','-metadata','track=3/12','-metadata','disc=2/3','-metadata','date=1987',
        '-metadata','compilation=1',str(source)],check=True)
    if args.tagged_aac:
        subprocess.run(['ffmpeg','-v','error','-i',str(out/'plain.m4a'),
                        '-c:a','copy','-f','adts',str(out/'plain.aac')],check=True)
        def frame(key, body):
            return key.encode() + struct.pack('>I',len(body)) + b'\0\0' + body
        tags = [('TIT2','Tagged Tïtle'),('TPE1','Track Artist'),('TALB','The Album'),
                ('TPE2','Album Artist'),('TCOM','Some Composer'),('TCON','Synthpop'),
                ('TRCK','3/12'),('TPOS','2/3'),('TYER','1987'),('TCMP','1')]
        frames = b''.join(frame(key,b'\1'+value.encode('utf-16')) for key,value in tags)
        frames += frame('APIC',b'\0image/png\0\3\0'+(out/'cover.png').read_bytes())
        size = len(frames)
        header = b'ID3\3\0\0' + bytes([(size>>21)&127,(size>>14)&127,(size>>7)&127,size&127])
        source = out/'Tagged Song.aac'
        source.write_bytes(header+frames+(out/'plain.aac').read_bytes())
    os.environ['LTM_AFC_READBACK'] = str(out/'afc'); (out/'afc').mkdir()
elif args.aac:
    source = out/"Song 'quoted' $title — été.aac"
    subprocess.run(['ffmpeg','-v','error','-i',str(ROOT/'contrib/it-harness/build/Payload/Harness.app/aac.m4a'),
                    '-c:a','copy','-f','adts',str(source)],check=True)
else:
    source = out/"Song 'quoted' $title — été.m4a"
    shutil.copyfile(ROOT/'contrib/it-harness/build/Payload/Harness.app/aac.m4a',source)
if args.recording:
    recorder = out/'recorder'
    subprocess.run(['xcrun','swiftc', *device_runtime.swift_flags(Path(__file__).resolve().parents[2]), DEVICE_PROFILE,'-swift-version','5','-default-isolation','MainActor',
        str(APP/'LightTouchMac/Features/ScreenMovieWriter.swift'),str(APP/'tests/fixtures/guest-audio-pump.swift'),str(APP/'tests/fixtures/recording-native.swift'),
        '-o',str(recorder)],check=True)
    class Embedded(r.Procs):
        def spawn(self,argv,logpath,env=None):
            if argv[0] == cfg.qemu:
                directory = Path(logpath).parent
                config = directory/'embedded-args.json'
                config.write_text(json.dumps(argv))
                argv = [str(recorder),str(Path(cfg.qemu).with_name('libqemu-arm.dylib')),
                        str(config),str(directory)]
            return super().spawn(argv,logpath,env)
    p = Embedded()
else:
    p = r.Procs()

def readback(folder, quadrants):
    """What the device keeps, read back over AFC: the item's tags in Library.itdb and its cover
    rendered into the purchased-item ArtworkCache under the item's store ID."""
    with sqlite3.connect(folder/'Library.itdb') as db:
        db.execute("ATTACH DATABASE ? AS loc", (str(folder/'Locations.itdb'),))
        row = db.execute("""SELECT item.title, item.artist, item.album, item.album_artist, item.composer,
                (SELECT genre FROM genre_map WHERE id=item.genre_id), item.track_number, item.track_count,
                item.disc_number, item.disc_count, item.year, item.is_compilation, item.total_time_ms,
                item.artwork_cache_id, (SELECT store_item_id FROM store_info WHERE item_pid=item.pid)
            FROM item NOT INDEXED WHERE is_song=1""").fetchone()
    print('LIBRARY', row, flush=True)
    *tags, duration, artwork_id, _ = row   # artwork_cache_id is the artworkDBRecordID MusicLibrary looks up
    tags = [unicodedata.normalize('NFC', t) if isinstance(t, str) else t for t in tags]
    expected = ['Tagged Tïtle','Track Artist','The Album','Album Artist','Some Composer','Synthpop',3,12,2,3,1987,1]
    assert tags == [unicodedata.normalize('NFC', t) if isinstance(t, str) else t for t in expected], (tags, expected)
    assert 5900 < duration < 6200, duration
    assert artwork_id, 'no artworkDBRecordID: MusicLibrary has no artwork key for the item'
    with sqlite3.connect(folder/'artwork.db') as db:
        formats = db.execute('SELECT format, offset, length, width, height, bytesPerRow, bitsPerPixel FROM artwork WHERE key=?',
                             (str(artwork_id),)).fetchall()
    print('ARTWORK', formats, flush=True)
    large = [f for f in formats if f[0] == 3005]
    assert large, ('no 3005 (320x320) rendering of the cover', formats)
    _, offset, length, width, height, row_bytes, bpp = large[0]
    assert (width, height, bpp) == (320, 320, 16), large
    pixels = (folder/'artwork.pix').read_bytes()[offset:offset+length]
    for (x, y), colour in quadrants:
        at = int(y*height)*row_bytes + int(x*width)*2
        v = pixels[at] | pixels[at+1] << 8   # L555: x1r5g5b5, little-endian
        actual = tuple(((v >> s) & 31) * 255 // 31 for s in (10, 5, 0))
        assert all(abs(a-b) <= 16 for a, b in zip(actual, colour)), ((x, y), actual, colour)
    print('PASS: tags and the cover read back over AFC from the device library and ArtworkCache', flush=True)

d = r.Device(cfg,p,'device')
server = None
def recording_marker(name, reply):
    (Path(d.dir)/name).touch()
    deadline = time.monotonic()+30
    while not (Path(d.dir)/reply).exists():
        assert d.alive() and time.monotonic()<deadline, reply
        time.sleep(0.1)
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
            # The app's agent wire: "<id> <op> <args>\n<base64 body>" -> "<id> <status>\n<base64 output>".
            wire = self.rfile.read(int(self.headers['Content-Length'])).decode()
            head, body = wire.split('\n', 1)
            ident, op, arguments = (head.split(' ', 2) + [''])[:3]
            status, output = r.itqmp.agent(d.qmp,op,arguments,base64.b64decode(body))
            result = ('%s %d\n%s' % (ident, status, base64.b64encode(output).decode())).encode()
            self.send_response(200)
            self.send_header('Content-Length',str(len(result)))
            self.end_headers()
            self.wfile.write(result)
        def log_message(self,*args):
            pass
    server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    manifest = out/'manifest.json'
    frameworks = Path(os.environ.get('LTM_FRAMEWORKS', '/opt/homebrew/lib'))   # where libimobiledevice loads from
    command = [str(executable),str(source),files,'127.0.0.1:'+str(cfg.mux_port),
        'http://127.0.0.1:'+str(server.server_port),str(frameworks),str(manifest)]
    if args.guest_tools: command.append(str(args.guest_tools.resolve()))
    subprocess.run(command,check=True,timeout=180, env=os.environ | {"LTM_HOST_SERVICE_WORKER": str(out / "LightTouchServices"), "LTM_SERVICE_FRAMEWORKS": str(frameworks)})
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
        assert status == 0 and data == (out/('prepared.m4v' if args.video else 'prepared.m4a')).read_bytes(), 'AFC bytes changed'
        if not args.aac and not args.tagged_aac and not args.video: assert data == source.read_bytes(), 'immutable copy changed'
        status, data = r.itqmp.agent(d.qmp,'get',
            '/var/mobile/Media/iTunes_Control/iTunes/iTunes Library.itlp/Library.itdb')
        assert status == 0
        database = out/'Library.itdb'
        database.write_bytes(data)
        with sqlite3.connect(database) as db:
            rows = db.execute('SELECT title FROM item WHERE is_song=0 AND media_kind=2' if args.video else 'SELECT title FROM item WHERE is_song=1').fetchall()
        title = 'Tagged Tïtle' if args.tagged else source.stem
        assert len(rows) == 1 and unicodedata.normalize('NFC',rows[0][0]) == unicodedata.normalize('NFC',title), rows
        if args.tagged:
            readback(out/'afc', QUADRANTS)
        bundle = 'com.apple.mobileipod'
    if args.video or args.tagged:
        assert d.powerdown(), 'guest shutdown not confirmed'
        print('PASS: native video conversion, AFC upload, one Videos library item, repeated import reconciliation and guest shutdown' if args.video
              else 'PASS: tagged song with art imported, tags and cover read back over AFC, guest shutdown',flush=True)
        sys.exit(0)
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
    if args.aac:
        status,front = r.itqmp.agent(d.qmp,'frontmost')
        assert status == 0 and front.startswith(bundle.encode()), 'Music exited after opening Songs: '+repr(front)
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
        status,front = r.itqmp.agent(d.qmp,'frontmost')
        assert status == 0 and front.startswith(bundle.encode()), 'Music exited during volume input: '+repr(front)
        # A one-song library has no Shuffle row; the song is the first row.
        if args.recording: recording_marker('record-start','record-ready')
        d.qmp.tap(130,88)
        time.sleep(2)
        if args.recording:
            d.qmp.cmd('stop'); time.sleep(2); d.qmp.cmd('cont')
        print('PLAYING',r.itqmp.agent(d.qmp,'frontmost'),flush=True)
        time.sleep(6)
        r.to_png(d.qmp.shot(str(out/'playing.ppm')),str(out/'playing.png'))
    if args.recording: recording_marker('record-stop','record-finished')
    assert d.powerdown(), 'guest shutdown not confirmed'
    if args.aac:
        audio = r.Result('converted AAC playback')
        assert r.verify_audio(str(out/'music.wav'),audio),audio.detail
        print('PASS: converted AAC played by native Music: '+audio.detail,flush=True)
    if args.recording:
        import numpy as np
        import wave
        movie = Path(d.dir)/'recording.mov'
        probe = json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-of','json',str(movie)]))
        streams = {s['codec_type']:s for s in probe['streams']}
        duration = float(streams['video']['duration'])
        assert 9 < duration < 15, duration
        assert abs(float(streams['audio']['duration'])-duration)<0.15
        decoded = out/'recording.wav'
        subprocess.run(['ffmpeg','-v','error','-i',str(movie),'-acodec','pcm_s16le',str(decoded)],check=True)
        with wave.open(str(decoded)) as wav:
            assert wav.getnchannels()==2 and wav.getframerate()==44100
            samples = np.frombuffer(wav.readframes(wav.getnframes()),dtype='<i2').reshape(-1,2).astype(float)
        gap = samples[int(2.7*44100):int(3.7*44100)]
        assert np.sqrt(np.mean(gap**2))<50, 'VM pause lost its silence'
        for start in (1.5,5.0):
            chunk = samples[int(start*44100):int((start+0.3)*44100)]
            for channel,hz in enumerate((440,880)):
                peak = np.fft.rfftfreq(len(chunk),1/44100)[np.argmax(np.abs(np.fft.rfft(chunk[:,channel])))]
                assert abs(peak-hz)<4 and np.sqrt(np.mean(chunk[:,channel]**2))>1000,(start,channel,peak)
        print('PASS: embedded QEMU recording, stereo Music, VM pause silence and resumed audio',movie,flush=True)
    print('PASS: native media preparation/upload, single library item, duplicate reconciliation and guest shutdown',flush=True)
finally:
    if server:
        server.shutdown()
        server.server_close()
    if d.qmp:
        d.qmp.close()
    p.stop_all()
