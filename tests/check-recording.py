#!/usr/bin/env python3
"""Production movie geometry and audio through portrait, landscape and rotation."""
from pathlib import Path
import subprocess,tempfile,wave
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='ltm-recording-check-') as tmp:
    tmp=Path(tmp)
    (tmp/'capture.c').write_text(r'''#include <stdint.h>
#include <math.h>
static double now;
static unsigned frame;
void fixture_time(double value) { now=value; }
uint64_t qemu_ios_audio_capture_start(void) { frame=0; return 1; }
double qemu_ios_audio_capture_time(uint64_t token) { return now; }
void qemu_ios_audio_capture_stop(uint64_t token) {}
int qemu_ios_audio_capture_read(uint64_t token,void *buffer,int capacity,double *seconds) {
 if(frame==44100)frame=88200;
 if(frame>=132300 || (frame+441)/44100.0>now)return 0;
 int16_t *samples=buffer;*seconds=frame/44100.0;
 for(unsigned i=0;i<441;i++,frame++) {
  samples[i*2]=12000*sin(2*M_PI*440*frame/44100.0);
  samples[i*2+1]=12000*sin(2*M_PI*880*frame/44100.0);
 }
 return 1764;
}
''')
    (tmp/'check.swift').write_text(r'''import AVFoundation
import CoreGraphics
@_silgen_name("fixture_time") func fixtureTime(_ seconds: Double)
@main struct Check {
 static func main() async throws {
  let context=CGContext(data:nil,width:320,height:480,bitsPerComponent:8,bytesPerRow:1280,
   space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
  context.setFillColor(CGColor(red:1,green:0.25,blue:0,alpha:1));context.fill(CGRect(x:0,y:0,width:320,height:480))
  let portrait=context.makeImage()!
  let wide=CGContext(data:nil,width:480,height:320,bitsPerComponent:8,bytesPerRow:1920,
   space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
  wide.setFillColor(CGColor(red:0,green:0.5,blue:1,alpha:1));wide.fill(CGRect(x:0,y:0,width:480,height:320))
  let landscape=wide.makeImage()!
  let mode=CommandLine.arguments[2]
  let writer=ScreenMovieWriter()
  let output=URL(fileURLWithPath:CommandLine.arguments[1])
  try await writer.start(url:output,recordGuestAudio:true)
  for tick in 0...30 {
   fixtureTime(Double(tick)/10)
   let image = mode == "landscape" || (mode == "rotated" && tick > 15) ? landscape : portrait
   try await writer.append(image,seconds:999) // Mixer and video must share the capture clock.
   try await Task.sleep(for:.milliseconds(10))
  }
  try await writer.finish(seconds:999)
  let asset=AVURLAsset(url:output)
  let audio=try await asset.loadTracks(withMediaType:.audio)
  let video=try await asset.loadTracks(withMediaType:.video)
  precondition(audio.count==1 && video.count==1)
  let size=try await video[0].load(.naturalSize)
  let expected:CGSize = mode == "portrait" ? CGSize(width:320,height:480) : mode == "landscape" ? CGSize(width:480,height:320) : CGSize(width:480,height:480)
  precondition(size == expected, "Unexpected dimensions: \(size)")
  let duration=try await asset.load(.duration)
  precondition(abs(duration.seconds-3)<0.1)
 }
}
''')
    subprocess.run(['clang','-c',str(tmp/'capture.c'),'-o',str(tmp/'capture.o')],check=True)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor',
        str(root/'LightTouchMac/ScreenMovieWriter.swift'),str(tmp/'check.swift'),str(tmp/'capture.o'),
        '-Xlinker','-export_dynamic','-o',str(tmp/'check')],check=True)
    centers = {}
    for mode in ('portrait','landscape','rotated'):
        subprocess.run([str(tmp/'check'),str(tmp/(mode+'.mov')),mode],check=True)
        subprocess.run(['ffmpeg','-v','error','-i',str(tmp/(mode+'.mov')),'-af','aresample=async=1:first_pts=0',
            '-acodec','pcm_s16le',str(tmp/(mode+'.wav'))],check=True)
        import numpy as np
        with wave.open(str(tmp/(mode+'.wav'))) as wav:
            assert wav.getnchannels()==2 and wav.getframerate()==44100
            audio=np.frombuffer(wav.readframes(wav.getnframes()),dtype='<i2').reshape(-1,2).astype(float)
        assert 2.9<len(audio)/44100<3.1,len(audio)/44100
        for start in (0.2,2.2):
            chunk=audio[int(start*44100):int((start+0.5)*44100)]
            for channel,hz in enumerate((440,880)):
                spectrum=np.abs(np.fft.rfft(chunk[:,channel]))
                peak=np.fft.rfftfreq(len(chunk),1/44100)[np.argmax(spectrum)]
                assert abs(peak-hz)<3,(start,channel,peak)
                assert np.sqrt(np.mean(chunk[:,channel]**2))>7000
        silence=audio[int(1.2*44100):int(1.8*44100)]
        assert np.sqrt(np.mean(silence**2))<50,'pause gap lost'
        width,height = {'portrait':(320,480),'landscape':(480,320),'rotated':(480,480)}[mode]
        for seconds in (0.5,2.5):
            pixels=subprocess.check_output(['ffmpeg','-v','error','-ss',str(seconds),'-i',str(tmp/(mode+'.mov')),
                '-frames:v','1','-f','rawvideo','-pix_fmt','rgb24','-'])
            pixels=np.frombuffer(pixels,dtype=np.uint8).reshape(height,width,3).astype(float)
            expected=np.array((0,128,255) if mode=='landscape' or (mode=='rotated' and seconds>1.5) else (255,64,0))
            assert np.max(np.abs(pixels[height//2,width//2]-expected))<30,(mode,pixels[height//2,width//2])
            centers[mode,seconds] = pixels[height//2,width//2]
            if mode!='rotated':
                # Native crop reaches every corner: no padding, no scaling.
                for y,x in ((4,4),(height-5,width-5)):
                    assert np.max(np.abs(pixels[y,x]-expected))<30
            else:
                assert np.max(pixels[4,4])<12,'rotation canvas lost its padding'
        print('PASS:',mode,'native dimensions, stereo audio, pause gap and final export')
    assert np.max(np.abs(centers['portrait',0.5]-centers['rotated',0.5]))<15
    assert np.max(np.abs(centers['landscape',2.5]-centers['rotated',2.5]))<15
