#!/usr/bin/env python3
"""Exercise the production package boot owner and BootSessionScope cancellation."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import device_runtime
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
# Package reports come from the imported runtime ABI.
DRIVER = r'''
import Foundation
enum DeviceToolsError: Error { case failed(String) }
@main struct Probe {
 @MainActor static func main() async throws {
    let offer = GuestPackage.Offer(bundled: 7, version: "1.7", serial: 7, glHook: true)
    let report = GuestPackageReport(serial: 7, result: 1)
    var record = DeviceInstance.Guest()
    record.seed = 1; record.bad = [7, 9]; record.builtIn = 6
    func observation(_ healthy: Bool, _ report: GuestPackageReport? = report,
                     _ record: DeviceInstance.Guest? = record) -> GuestPackageSession.Observation {
        .init(report: report, record: record, glesProtocol: 1, healthy: healthy)
    }
    var session = GuestPackageSession(offer: offer)
    let first = session.observe(observation(true), elapsed: .seconds(1))!
    precondition(first.changedReport == report && first.verdict == nil)
    first.apply(to: &record)
    precondition(record.active == 7 && record.bad == [7, 9])
    precondition(session.observe(observation(true), elapsed: .seconds(9))!.changedReport == nil)
    // Losing guest health must reset the continuous qualification interval.
    precondition(session.observe(observation(false), elapsed: .seconds(10))!.verdict == nil)
    precondition(session.observe(observation(true), elapsed: .seconds(11))!.verdict == nil)
    precondition(session.observe(observation(true), elapsed: .seconds(20))!.verdict == nil)
    let good = session.observe(observation(true), elapsed: .seconds(21))!
    precondition(good.verdict == .good(7) && good.changesRecord)
    good.apply(to: &record)
    precondition(record.lastGood == 7 && record.bad == [9] && record.seed == 1 && record.builtIn == 6)
    precondition(session.observe(observation(true), elapsed: .seconds(22)) == nil,
                 "one boot must never publish a second verdict")

    var bad = GuestPackageSession(offer: offer)
    var fresh = DeviceInstance.Guest(); fresh.seed = 1
    precondition(bad.observe(observation(false, report, fresh), elapsed: .seconds(299))!.verdict == nil)
    let failure = bad.observe(observation(false, report, fresh), elapsed: .seconds(300))!
    precondition(failure.verdict == .bad(7))
    failure.apply(to: &fresh); failure.apply(to: &fresh)
    precondition(fresh.bad == [7], "retrying record publication must not duplicate bad serials")
    for protected in [Int64(1), Int64(7)] {
        var protectedSession = GuestPackageSession(offer: offer)
        let protectedReport = GuestPackageReport(serial: protected, result: 0)
        let result = protectedSession.observe(observation(false, protectedReport, record), elapsed: .seconds(300))!
        precondition(result.verdict == .undecided && result.changedReport == protectedReport)
        var saved = record; result.apply(to: &saved)
        precondition(saved.bad == record.bad && saved.active == protected)
    }
    var legacy = GuestPackageSession(offer: offer)
    precondition(legacy.observe(observation(true, nil), elapsed: .seconds(1))!.verdict == nil)
    precondition(legacy.observe(observation(true, nil), elapsed: .seconds(30))!.verdict == nil)
    let legacyResult = legacy.observe(observation(true, nil), elapsed: .seconds(31))!
    precondition(legacyResult.verdict == .legacy && legacyResult.status == .legacy && !legacyResult.changesRecord)
    var incompatible = GuestPackageSession(offer: offer)
    var incompatibleObservation = observation(true); incompatibleObservation.glesProtocol = 100
    precondition(incompatible.observe(incompatibleObservation, elapsed: .zero)!.status == .outOfDate)

    // Actual async owner under the actual boot task owner. Retirement must
    // prevent delayed sampling/publication, and renewal must use fresh state.
    let scope = BootSessionScope()
    var samples = 0, writes = 0
    scope[.guestPackage] = Task {
        await GuestPackageSession.watch(offer: offer, interval: .milliseconds(100), sample: {
            samples += 1; return observation(true)
        }, publish: { _ in writes += 1 })
    }
    await Task.yield()
    let retiredTask = scope[.guestPackage]!
    scope.retire()
    await retiredTask.value
    try await Task.sleep(for: .milliseconds(130))
    precondition(samples == 0 && writes == 0, "a retired boot published delayed package state")
    scope.renew()
    scope[.guestPackage] = Task {
        await GuestPackageSession.watch(offer: offer, interval: .milliseconds(1), sample: {
            samples += 1; return samples == 1 ? observation(true) : nil
        }, publish: { update in
            precondition(update.changedReport == report && update.verdict == nil)
            writes += 1
        })
    }
    await scope[.guestPackage]?.value
    precondition(samples == 2 && writes == 1, "new boot must not reuse a retired boot's seen report")
    var activeWrites = 0
    let activeWatch = Task {
        await GuestPackageSession.watch(offer: offer, interval: .milliseconds(30), sample: {
            observation(true)
        }, publish: { _ in activeWrites += 1 })
    }
    for _ in 0..<100 where activeWrites == 0 {
        try await Task.sleep(for: .milliseconds(1))
    }
    precondition(activeWrites == 1)
    activeWatch.cancel()
    await activeWatch.value
    try await Task.sleep(for: .milliseconds(50))
    precondition(activeWrites == 1, "cancellation after a report must prevent the next publication")
    var stoppedSamples = 0
    await GuestPackageSession.watch(offer: offer, interval: .milliseconds(1), sample: {
        stoppedSamples += 1; return nil
    }, publish: { _ in preconditionFailure("missing observation must stop the owner") })
    precondition(stoppedSamples == 1)
    scope.retire()
    print("PASS: production qualification owns health budgets, record verdicts and one-shot completion; boot cancellation prevents delayed publication")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-package-session-') as temporary:
    folder = Path(temporary)
    main = folder / 'probe.swift'
    main.write_text(DRIVER)
    executable = folder / 'probe'
    sources = [
        'Packages/FirmwareKit/Sources/FirmwareSchema/FirmwareWire.swift',
        'LightTouchMac/Guest/GuestPackage.swift',
        'LightTouchMac/Device/BootSessionScope.swift',
        'LightTouchMac/Library/DeviceInstance.swift',
        'LightTouchMac/Device/DeviceProfile.swift',
        'LightTouchMac/Library/StorageLocations.swift',
        'LightTouchMac/Library/FirmwareCatalog.swift',
    ]
    subprocess.run(['xcrun', 'swiftc', *device_runtime.swift_flags(Path(__file__).resolve().parents[2]), '-swift-version', '5', '-default-isolation', 'MainActor',
                    '-parse-as-library', '-module-cache-path', str(folder / 'modules'),
                    *[str(ROOT / source) for source in sources], str(main), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=10)
