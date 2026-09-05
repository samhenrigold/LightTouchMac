import AVFoundation
import CoreGraphics
import Foundation

@main struct Check {
 static func frame(_ w:Int,_ h:Int,_ red:CGFloat,_ green:CGFloat)->CGImage {
  let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
  c.setFillColor(CGColor(red:red,green:green,blue:0,alpha:1));c.fill(CGRect(x:0,y:0,width:w,height:h));return c.makeImage()!
 }
 static func pixel(_ image:CGImage,_ x:Int,_ y:Int)->[Int] {
  let c=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
  c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
  let data=c.data!.assumingMemoryBound(to:UInt8.self)
  return (0..<3).map { Int(data[(y*image.width+x)*4+$0]) }
 }
 static func main() async throws {
  let directory=FileManager.default.temporaryDirectory.appendingPathComponent("ltm-capture-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
  defer { try? FileManager.default.removeItem(at:directory) }
  let url=directory.appendingPathComponent("check.mov")
  let original=frame(320,480,1,0)
  let originalDestination=CGImageDestinationCreateWithURL(directory.appendingPathComponent("original.png") as CFURL,"public.png" as CFString,1,nil)!
  CGImageDestinationAddImage(originalDestination,original,nil);precondition(CGImageDestinationFinalize(originalDestination))
  let writer=ScreenMovieWriter()
  try await writer.start(url:url)
  for i in 0..<15 {
   try await writer.append(frame(320,480,1,0),seconds:Double(i)/30)
   try await Task.sleep(for:.milliseconds(5))
  }
  for i in 15..<30 {
   try await writer.append(frame(480,320,0,1),seconds:Double(i)/30)
   try await Task.sleep(for:.milliseconds(5))
  }
  try await writer.finish(seconds:1)
  let asset=AVURLAsset(url:url)
  let duration=try await asset.load(.duration)
  let tracks=try await asset.loadTracks(withMediaType:.video)
  precondition(tracks.count==1)
  let size=try await tracks[0].load(.naturalSize)
  precondition(size==CGSize(width:480,height:480))
  precondition(abs(duration.seconds-1)<0.05)
  let generator=AVAssetImageGenerator(asset:asset)
  generator.requestedTimeToleranceBefore = .zero
  generator.requestedTimeToleranceAfter = .zero
  for (time,name) in [(0.2,"portrait"),(0.7,"landscape")] {
   let result=try await generator.image(at:CMTime(seconds:time,preferredTimescale:600))
   let source = name == "portrait" ? frame(320,480,1,0) : frame(480,320,0,1)
   let expected = pixel(source,100,100), actual = pixel(result.image,240,240)
   precondition(zip(expected,actual).allSatisfy { abs($0-$1)<6 }, "Color changed: \(expected) -> \(actual)")
   let margin = name == "portrait" ? pixel(result.image,10,240) : pixel(result.image,240,10)
   precondition(margin.allSatisfy { $0<5 })
   let destination=CGImageDestinationCreateWithURL(directory.appendingPathComponent("\(name).png") as CFURL,"public.png" as CFString,1,nil)!
   CGImageDestinationAddImage(destination,result.image,nil);precondition(CGImageDestinationFinalize(destination))
  }
  print("PASS: native H.264 encode/decode, one-second timeline, portrait/landscape on stable canvas")
 }
}
