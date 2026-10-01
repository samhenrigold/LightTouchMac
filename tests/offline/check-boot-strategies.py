#!/usr/bin/env python3
"""Compile the production boot recipe; strategies own their required inputs."""
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='ltm-boot-strategies-') as tmp:
    work = Path(tmp)
    (work / 'main.swift').write_text(r'''
import Foundation
func require(_ yes: Bool, _ message: String) { if !yes { fatalError(message) } }
func machine(_ boot: BootRecipe.IPadBoot) -> String {
    let config = BootRecipe.iPad(.init(boot: boot, nand: "nand", overlay: "overlay", dieID: "1:2", usbAddress: nil, wifi: false), serial: "null", audio: [], netdev: nil, restore: [])
    return config.argv[2]
}
let kernel = machine(.kernel(image: "kernel", writableNOR: nil))
let iboot = machine(.iBoot(image: "iboot", writableNOR: "nor", gidBlobs: "keys"))
let rom = machine(.secureROM(image: "rom", writableNOR: "nor", gidBlobs: "keys", developmentFuses: false))
require(kernel.contains("kboot=kernel") && !kernel.contains("iboot="), "kernel strategy")
require(iboot.contains("iboot=iboot") && iboot.contains("gid-blobs=keys") && !iboot.contains("kboot="), "iBoot strategy")
require(rom.contains("bootrom=rom") && rom.contains("development-fuses=off") && !rom.contains("iboot="), "ROM strategy")
for strategy in ["iboot", "bootrom"] {
    do { _ = try BootRecipe.preparedIPadBoot(strategy: strategy, image: "image", writableNOR: nil, gidBlobs: "keys"); fatalError("missing NOR accepted") }
    catch { }
    do { _ = try BootRecipe.preparedIPadBoot(strategy: strategy, image: "image", writableNOR: "nor", gidBlobs: nil); fatalError("missing keys accepted") }
    catch { }
}
do { _ = try BootRecipe.preparedIPadBoot(strategy: "typo", image: "image", writableNOR: nil, gidBlobs: nil); fatalError("unknown strategy accepted") }
catch { }
let legacy = try BootRecipe.preparedIPadBoot(strategy: nil, image: "image", writableNOR: nil, gidBlobs: "stray keys") == .kernel(image: "image", writableNOR: nil)
require(legacy, "legacy lock explicitly defaults to kernel, independent of keys")
let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let lock = dir.appendingPathComponent("device.lock.json")
func writeLock(_ board: String, _ machine: [String: String]) throws {
    try JSONSerialization.data(withJSONObject: ["board": board, "machine": machine]).write(to: lock)
}
try JSONSerialization.data(withJSONObject: ["wifi-mac": "02:11:22:33:44:66", "bt-mac": "02:11:22:33:44:67"]).write(to: dir.appendingPathComponent("identity.json"))
try writeLock("n72ap", ["aes-uid": "engine"])
require(BootRecipe.lockMachine(lock) == ["aes-uid": "engine", "wifi-mac": "02:11:22:33:44:66", "bt-mac": "02:11:22:33:44:67"], "existing N72 unit provisions card from identity")
try writeLock("n72ap", ["wifi-mac": "02:11:22:33:44:88"])
require(BootRecipe.lockMachine(lock)["wifi-mac"] == "02:11:22:33:44:88", "explicit card provisioning wins")
try writeLock("k48ap", [:])
require(BootRecipe.lockMachine(lock).isEmpty, "other boards do not acquire an N72 card option")
try writeLock("n72ap", [:])
try FileManager.default.removeItem(at: dir.appendingPathComponent("identity.json"))
require(BootRecipe.lockMachine(lock).isEmpty, "legacy N72 with no identity preserves default")
print("PASS: explicit kernel/iBoot/ROM strategies, missing inputs and unknown strategy rejection")
''')
    exe = work / 'check'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(work/'modules'), str(root/'LightTouchMac/Device/BootRecipe.swift'), str(root/'Shared/DeviceLinkProtocol.swift'), str(work/'main.swift'), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
