#!/usr/bin/env python3
"""Every listing of the firmware catalog is per board, in version order.

FirmwareCatalog.load sorts on load: boards keep the order the file introduces them; within a board entries
sort by marketing version, and within a version its betas and GMs come before the release, by release date
(by beta/GM number where undated), build as the last tiebreak, whatever order the JSON has. So 4.3.x stays
together and a 5.0 beta that came out before 4.3.4 lists after 4.3.5, just before 5.0 (user, 09-30; the
earlier date-first order interleaved them). The shipped catalog must load in that order too: every entry
dated, versions ascending per board, dates ascending within a version, 4.1 betas before 4.1.
"""
from pathlib import Path
import json, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
shipped = root / "LightTouchMac/Resources/firmware-catalog.json"
source = r'''import Foundation
@main struct Check {
 static func main() throws {
  let args = CommandLine.arguments
  let c = try FirmwareCatalog.load(from: URL(fileURLWithPath: args[1]))
  let order = c.entries.map { "\($0.board) \($0.version) \($0.build)" }
  precondition(order == ["n72ap 2.1.1 5F138", "n72ap 3.1.3 7E18", "n72ap 3.1.3 7E18b",
                         "n72ap 4.1 8B5080c", "n72ap 4.1 8B5091b", "n72ap 4.1 8B117",
                         "n72ap 4.2 8C5115c", "n72ap 4.2 8C134", "n72ap 4.2 8C134b", "n72ap 4.2.1 8C148",
                         "k48ap 3.2 7B367", "k48ap 3.2.2 7B500", "k48ap 4.2.1 8C148",
                         "k48ap 4.3.3 8J3", "k48ap 4.3.4 8K2", "k48ap 4.3.5 8L1", "k48ap 5.0 9A5220p", "k48ap 5.0 9A334"], "\(order)")
  let badges = c.entries.compactMap(\.prereleaseBadge)
  precondition(badges == ["Beta 1", "Beta 2", "Beta 3", "GM 1", "GM 2", "Beta 1"], "\(badges)")
  let s = try FirmwareCatalog.load(from: URL(fileURLWithPath: args[2]))
  func version(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0)! } }
  for board in Set(s.entries.map(\.board)) {
   let listed = s.entries.filter { $0.board == board }
   precondition(listed.allSatisfy { $0.released != nil }, "\(board): an undated entry")
   for (a, b) in zip(listed, listed.dropFirst()) {
    precondition(!version(b.version).lexicographicallyPrecedes(version(a.version)), "\(board): \(a.build) (\(a.version)) before \(b.build) (\(b.version))")
    precondition(a.version != b.version || a.released! <= b.released!, "\(board) \(a.version): \(a.build) before \(b.build)")
    precondition(a.version != b.version || a.prerelease != nil || b.prerelease == nil, "\(board) \(a.version): the release before \(b.build)")
   }
  }
  let ipad = s.entries.filter { $0.board == "k48ap" }.map { "\($0.version) \($0.prereleaseBadge ?? "")" }
  let from433 = ipad.drop { $0 != "4.3.3 " }.prefix(5)
  precondition(Array(from433) == ["4.3.3 ", "4.3.4 ", "4.3.5 ", "5.0 Beta 1", "5.0 Beta 5"], "\(ipad)")
  let ipod41 = s.entries.filter { $0.board == "n72ap" && $0.version == "4.1" }.map(\.build)
  precondition(ipod41 == ["8B5080c", "8B5091b", "8B5097d", "8B117"], "\(ipod41)")
  precondition(s.entries.allSatisfy { $0.prerelease == nil || $0.prereleaseBadge?.last?.isNumber == true })
  print("PASS: catalog entries list per board in version order (a version's betas and GMs by date, then its release); the shipped catalog too")
 }
}
'''
def entry(board, product, version, build, prerelease=None, number=None, released=None):
    e = {"id": f"{board}-{build}", "board": board, "product_type": product, "version": version, "build": build, "status": "available",
         "source": {"kind": "ipsw"}, "keys": {}, "emulator": {"min_protocol": 1},
         "estimates": {"seconds": 1, "prepared_bytes": 1, "peak_bytes": 1}}
    if prerelease: e["prerelease"] = prerelease
    if number: e["prerelease_number"] = number
    if released: e["released"] = released
    return e
ipod, ipad = ("n72ap", "iPod2,1"), ("k48ap", "iPad1,1")
fixture = {"format": 1, "entries": [
    entry(*ipod, "3.1.3", "7E18b"), entry(*ipod, "4.1", "8B117"), entry(*ipod, "3.1.3", "7E18"),
    entry(*ipod, "4.1", "8B5091b", "beta", 2), entry(*ipod, "4.2.1", "8C148"), entry(*ipad, "3.2.2", "7B500"),
    entry(*ipod, "4.2", "8C134b", "gm", 2), entry(*ipod, "4.2", "8C134", "gm"), entry(*ipod, "4.2", "8C5115c", "beta", 3),
    entry(*ipod, "4.1", "8B5080c", "beta"), entry(*ipod, "2.1.1", "5F138"), entry(*ipad, "3.2", "7B367"),
    entry(*ipad, "4.2.1", "8C148"),
    # Dated: 5.0 beta 1 came out between 4.3.3 and 4.3.4; the undated 4.2.1 above keeps its version slot.
    entry(*ipad, "5.0", "9A334", released="2011-10-12"), entry(*ipad, "4.3.5", "8L1", released="2011-07-25"),
    entry(*ipad, "5.0", "9A5220p", "beta", 1, released="2011-06-07"), entry(*ipad, "4.3.4", "8K2", released="2011-07-15"),
    entry(*ipad, "4.3.3", "8J3", released="2011-05-04")]}
with tempfile.TemporaryDirectory(prefix="ltm-catalog-order-") as d:
    p = Path(d) / "check.swift"
    p.write_text(source)
    (Path(d) / "catalog.json").write_text(json.dumps(fixture))
    subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", d + "/modules", str(root / "LightTouchMac/Library/FirmwareCatalog.swift"),
                    str(root / "LightTouchMac/Device/DeviceProfile.swift"), str(p), "-o", d + "/check"], check=True)
    subprocess.run([d + "/check", d + "/catalog.json", str(shipped)], check=True, timeout=20)
