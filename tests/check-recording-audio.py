#!/usr/bin/env python3
"""Production movie writer: stereo audio, a paused interval, video and final drain."""
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
  let image=context.makeImage()!
  let writer=ScreenMovieWriter()
  let output=URL(fileURLWithPath:CommandLine.arguments[1])
  try await writer.start(url:output,recordGuestAudio:true)
  for tick in 0...30 {
   fixtureTime(Double(tick)/10)
   try await writer.append(image,seconds:999) // Mixer and video must share the capture clock.
   try await Task.sleep(for:.milliseconds(10))
  }
  try await writer.finish(seconds:999)
  let asset=AVURLAsset(url:output)
  let audio=try await asset.loadTracks(withMediaType:.audio)
  let video=try await asset.loadTracks(withMediaType:.video)
  precondition(audio.count==1 && video.count==1)
  let duration=try await asset.load(.duration)
  precondition(abs(duration.seconds-3)<0.1)
 }
}
''')
    subprocess.run(['clang','-c',str(tmp/'capture.c'),'-o',str(tmp/'capture.o')],check=True)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor',
        str(root/'LightTouchMac/ScreenMovieWriter.swift'),str(tmp/'check.swift'),str(tmp/'capture.o'),
        '-Xlinker','-export_dynamic','-o',str(tmp/'check')],check=True)
    subprocess.run([str(tmp/'check'),str(tmp/'movie.mov')],check=True)
    subprocess.run(['ffmpeg','-v','error','-i',str(tmp/'movie.mov'),'-af','aresample=async=1:first_pts=0',
        '-acodec','pcm_s16le',str(tmp/'audio.wav')],check=True)
    import numpy as np
    with wave.open(str(tmp/'audio.wav')) as wav:
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
    print('PASS: production AAC/video tracks, shared clock, stereo tones, one-second pause gap and completed export')
