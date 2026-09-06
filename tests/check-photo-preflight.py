#!/usr/bin/env python3
"""Actual ImageIO photo preflight: orientation, size, alpha, JPEG and cancellation."""
from pathlib import Path
from PIL import Image, ImageDraw
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='ltm-photo-check-') as work:
    work = Path(work)
    source = Image.new('RGB',(4096,2048),(220,30,30))
    ImageDraw.Draw(source).rectangle((2048,0,4095,2047),fill=(30,30,220))
    exif = Image.Exif()
    exif[274] = 6
    source.save(work/'rotated.jpg',exif=exif)
    alpha = Image.new('RGBA',(300,200),(0,0,0,0))
    ImageDraw.Draw(alpha).rectangle((100,50,199,149),fill=(220,30,30,255))
    alpha.save(work/'alpha.png')
    (work/'broken.png').write_bytes(b'not an image')
    swift = r"""
import Foundation
enum DeviceToolsError: Error { case failed(String) }
@main struct Check {
    static func main() async throws {
        let work = URL(fileURLWithPath:CommandLine.arguments[1])
        for name in ["rotated.jpg","alpha.png"] {
            let photo = try await MediaPhoto.prepare(work.appendingPathComponent(name))
            defer { try? FileManager.default.removeItem(at: photo.directory) }
            precondition(UUID(uuidString:photo.id) != nil)
            try FileManager.default.copyItem(at:photo.image,to:work.appendingPathComponent(name + ".prepared.jpg"))
        }
        do { _ = try await MediaPhoto.prepare(work.appendingPathComponent("broken.png")); fatalError("accepted malformed image") }
        catch {}
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await MediaPhoto.prepare(work.appendingPathComponent("alpha.png")); fatalError("ignored cancellation") }
            catch is CancellationError {}
        }
        try await task.value
    }
}
"""
    (work/'check.swift').write_text(swift)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor',
        '-module-cache-path',str(work/'modules'),str(root/'LightTouchMac/MediaPhoto.swift'),
        str(work/'check.swift'),'-o',str(work/'check')],check=True)
    subprocess.run([str(work/'check'),str(work)],check=True)
    with Image.open(work/'rotated.jpg.prepared.jpg') as image:
        assert image.size == (1024,2048),image.size
        assert not image.info.get('progressive',False)
        assert image.getpixel((512,256))[0] > 180
        assert image.getpixel((512,1792))[2] > 180
    with Image.open(work/'alpha.png.prepared.jpg') as image:
        assert image.size == (300,200),image.size
        assert min(image.getpixel((10,10))) > 245,'transparent area did not become white'
        assert image.getpixel((150,100))[0] > 180
    print('PASS: production photo orientation, bounded dimensions, baseline JPEG, white alpha background, malformed input and cancellation')
