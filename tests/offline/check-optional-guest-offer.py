#!/usr/bin/env python3
"""Optional developer failures cannot suppress required guest additions."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
s=(root/'LightTouchMac/Device/EmulatorController.swift').read_text()
a=s.index('    private func composeGuestOffer()');b=s.index('    /// Judge this boot',a)
method=s[a:b].replace('private func composeGuestOffer','func composeGuestOffer',1)
source=r'''import Foundation
@MainActor enum Bundled {static let filesRoot=URL(fileURLWithPath:ProcessInfo.processInfo.environment["OFFER_TEST_ROOT"]!)}
struct Instance {let board="n72ap",firmware="n72ap-7E18";struct Paths{let work:URL};let paths=Paths(work:URL(fileURLWithPath:ProcessInfo.processInfo.environment["OFFER_TEST_ROOT"]!))}
@MainActor enum GuestPackage {
 struct Offer {let serial:Int64;let version:String}
 static var calls=0,builtinFails=false
 static func arch(board:String)->String?{"armv6"}
 static func bundledPack(arch:String,filesRoot:URL)->URL?{filesRoot}
 static func compose(itpack:URL,board:String,build:String,lock:Int?,guest:Int?,into:URL,augment:((URL,Int64)throws->(serial:Int64,version:String))?=nil)throws->Offer? {
  calls+=1
  if let augment {let r=try augment(into,2);return Offer(serial:r.serial,version:r.version)}
  if builtinFails {throw CocoaError(.fileReadCorruptFile)}
  return Offer(serial:2,version:"built-in")
 }
}
@MainActor enum GuestDeveloperTools {
 static var failOptional=true
 static func augmentation(instance:Instance,build:String)->((URL,Int64)throws->(serial:Int64,version:String))? {
  if !failOptional{return nil}
  return {_ ,_ in throw CocoaError(.fileReadCorruptFile)}
 }
}
@MainActor final class Controller {
 struct Status {let guestPackageSupported=true}
 let status:Status?=Status(),instance=Instance()
 var guestOffer:GuestPackage.Offer?
 var guestOfferDirectory:URL{instance.paths.work.appendingPathComponent("offer")}
 var lockRecord:Int?{nil};var guestRecord:Int?{nil}
 func logEvent(_ message:String){}
'''+method+r'''}
@main struct Probe {
 @MainActor static func main() {
  let fallback=Controller();precondition(fallback.composeGuestOffer() != nil)
  precondition(fallback.guestOffer?.version=="built-in" && GuestPackage.calls==2)
  GuestPackage.calls=0;GuestDeveloperTools.failOptional=false
  let ordinary=Controller();precondition(ordinary.composeGuestOffer() != nil && GuestPackage.calls==1)
  GuestPackage.builtinFails=true
  let badBuiltin=Controller();precondition(badBuiltin.composeGuestOffer()==nil && badBuiltin.guestOffer==nil)
  print("PASS: developer failure preserves built-in additions; invalid mandatory package still fails closed")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-offer-fallback-') as temporary:
 folder=Path(temporary);main=folder/'main.swift';main.write_text(source);binary=folder/'probe'
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(main),'-o',str(binary)],check=True)
 import os
 subprocess.run([str(binary)],env={**os.environ,'OFFER_TEST_ROOT':str(folder)},check=True)
