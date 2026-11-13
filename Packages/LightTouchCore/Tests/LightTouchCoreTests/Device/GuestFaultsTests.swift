import Foundation
import Testing

@testable import LightTouchCore

/// A boot that comes up wrong is named: the recorded iPad 4.2.1 boot (both volumes mounted) has no fault, and lines from
/// real logs (the iPhone 3GS 3.1.3 data volume refused, issue 97; a crashed mediaserverd; a kernel panic) each give
/// theirs, through the whole-log judge sessions single runs and through the app's serial watch.
struct GuestFaultsTests {
    static let refused = """
        com.apple.launchd 1\tcom.apple.launchd 1\t*** launchd[1] has started up. ***
        Running fsck on the boot volume...
           Invalid content in Journal
        /dev/disk0s1 on / (hfs, local, noatime)
        mount_hfs: Invalid argument
        Bug: launchctl.c:3683 (23906):2: fwexec(mount_tool, NULL) != -1
        """

    @Test func theRecordedBootHasNoFault() throws {
        let log = try Data(contentsOf: repositoryRoot.appendingPathComponent("tests/fixtures/serial-k48ap-8C148.log"))
        #expect(GuestFaults.faults(log: String(decoding: log, as: UTF8.self), dataVolume: true) == [])
    }

    @Test func anUnmountedDataVolumeIsAFault() {
        let faults = GuestFaults.faults(log: Self.refused, dataVolume: true)
        #expect(faults.contains { $0.hasPrefix("the data volume didn't mount") && $0.hasSuffix("(on 1 of 1 boots)") })
        #expect(faults.contains { $0.hasPrefix("launchd couldn't mount") })
        #expect(faults.contains { $0.hasPrefix("a volume's journal is unreadable") })
        // A one-volume device (the iPod touch 2G, the iPhone 2G) has no /private/var line to miss.
        #expect(
            !GuestFaults.faults(log: "/dev/disk0s1 on / (hfs, local)\n", dataVolume: false).contains {
                $0.hasPrefix("the data volume")
            }
        )
        // A second boot that mounts it doesn't hide the first that didn't.
        let twice = Self.refused + "\n/dev/disk0s1 on / (hfs)\n/dev/disk0s2 on /private/var (hfs)\n"
        #expect(GuestFaults.faults(log: twice, dataVolume: true).contains { $0.hasSuffix("(on 1 of 2 boots)") })
    }

    @Test func crashesPanicsAndFailedChecksAreFaults() {
        let log = """
            Oct 17 11:11:18 launchd[1]: 16/com.apple.mediaserverd: Exited abnormally: Abort trap
            Oct 17 11:11:19 launchd[1]: 16/com.apple.SpringBoard: Exited: Terminated
            fsck exited with status: 8
            panic(cpu 0 caller 0x80a74efb): "CDMA: client driver(s) left channel(s) 0x2 active when sleeping"
            fsck exited with status: 0
            """
        let faults = GuestFaults.faults(log: log, dataVolume: false)
        #expect(faults.count == 3, "\(faults)")
        #expect(faults.contains { $0.hasPrefix("a system process crashed (1×): Oct 17") })
        #expect(faults.contains { $0.hasPrefix("the file system check failed (1×): fsck exited with status: 8") })
        #expect(faults.contains { $0.hasPrefix("the iOS kernel panicked") })
        #expect(
            GuestFaults.line("panic(cpu ", in: log)
                == #"panic(cpu 0 caller 0x80a74efb): "CDMA: client driver(s) left channel(s) 0x2 active when sleeping""#
        )
        #expect(GuestFaults.line("fsck exited with status: 8", in: log) == "fsck exited with status: 8")
        #expect(GuestFaults.line("Invalid content in Journal", in: log) == nil)
    }

    /// A crash report written during this boot names its process, once; one from before the boot, a LatestCrash link,
    /// a sandbox violation and the logs beside them don't. The listings are the sweep's: an iPhone 3GS 4.1 boot whose
    /// SpringBoard crashed (a mediaserverd report left from its preparation two weeks before), an iPhone 4 7.0 beta 2
    /// boot (it_seal's report, ubd's sandbox reports and securebackupd's logs) and a 7.1.2 one (.ips).
    @Test func crashReportsFromThisBootNameTheirProcess() {
        let ios41: [String: Double] = [
            "LatestCrash-mediaserverd.plist": 1_277_758, "LatestCrash-SpringBoard.plist": 37, "LatestCrash.plist": 37,
            "mediaserverd_2026-10-05-011507_iPhone.plist": 1_277_758, "SpringBoard_2026-10-19-201030_iPhone.plist": 37
        ]
        #expect(GuestFaults.crashedProcesses(ages: ios41, uptime: 62) == ["SpringBoard"])
        let ios70: [String: Double] = [
            "AirTraffic/airtraffic.log": 28, "com.apple.asl.1371297605": 132,
            "DiagnosticLogs/securebackupd_2013-06-15-050152.log": 84, "DiagnosticLogs/securebackupd.log": 25,
            "it_seal_2013-06-15-050106_iPhone.plist": 71, "MobileBackup/MobileBackup.log": 111,
            "Sandbox-ubd-2013-06-15-050049.plist": 88, "Sandbox-ubd-2013-06-15-080209.plist": 8
        ]
        #expect(GuestFaults.crashedProcesses(ages: ios70, uptime: 138) == ["it_seal"])
        let ios712: [String: Double] = [
            "it_seal_2026-10-19-214220_iPhone.ips": 3, "stacks-2026-10-18-093555.ips": 119_188,
            "stacks+MobileMail-2026-10-19-184126.ips": 57, "DiagnosticLogs/security.log.20261020T014048Z": 82
        ]
        #expect(GuestFaults.crashedProcesses(ages: ios712, uptime: 117) == ["it_seal", "stacks+MobileMail"])
        // An iPhone 4 4.2.1 boot: mediaserverd's report and the system log snapshot taken with it (bug_type 116).
        let ios421: [String: Double] = [
            "mediaserverd_2026-10-19-224443_iPhone.plist": 40, "SystemLog_2026-10-19-224353.plist": 90
        ]
        #expect(GuestFaults.crashedProcesses(ages: ios421, uptime: 120) == ["mediaserverd"])
        // jetsam's report and a panic count; nothing does on an empty folder.
        let other: [String: Double] = [
            "LowMemory-2011-03-01-120102.plist": 600, "Panics/panic-full-2011-03-01-120102.plist": 5
        ]
        #expect(GuestFaults.crashedProcesses(ages: other, uptime: 300) == ["panic-full"])
        #expect(GuestFaults.crashedProcesses(ages: other, uptime: 1000) == ["LowMemory", "panic-full"])
        #expect(GuestFaults.crashedProcesses(ages: [:], uptime: 300) == [])
        #expect(!GuestFaults.listsCrashReports(version: "1.1.5") && GuestFaults.listsCrashReports(version: "2.1.1"))
    }

    /// A run from a prepared base counts every report the base didn't carry, whatever its age, from whichever
    /// CrashReporter folder the base had it in. An iPhone 4 7.1.2 base's seal boot left a stackshot in
    /// /var/logs/CrashReporter, which crash_mover moved to mobile's at the run's boot, 166 s old at 75 s up.
    @Test func aRunCountsOnlyReportsTheBaseDidNotCarry() {
        let base = [
            "logs/CrashReporter", "logs/CrashReporter/Panics", "logs/CrashReporter/stacks-2026-10-20-032811.ips",
            "mobile/Library/Logs/CrashReporter/DiagnosticLogs/security.log.20261020T102812Z",
            "mobile/Library/Logs/CrashReporter/it_seal_2013-06-15-050106_iPhone.plist",
            "wireless/Library/Logs/CrashReporter/CommCenter_2026-10-20-032830_iPhone.plist",
            "mobile/Library/Preferences/SpringBoard_2026-10-20-032811_iPhone.plist"
        ]
        let listed = [
            "stacks-2026-10-20-032811.ips", "it_seal_2013-06-15-050106_iPhone.plist",
            "CommCenter_2026-10-20-032830_iPhone.plist", "DiagnosticLogs/security.log.20261020T103025Z",
            "SpringBoard_2026-10-20-032811_iPhone.plist", "Panics/panic-full-2013-06-15-050106.plist"
        ]
        #expect(GuestFaults.crashedProcesses(listed: listed, base: base) == ["SpringBoard", "panic-full"])
        #expect(GuestFaults.crashedProcesses(listed: listed, base: []).count == 5)
    }

    /// The app's watch sees the same: the phrases in order, across writes, then the mount rule once iOS answers.
    @Test func theAppsWatchSeesTheFaults() async throws {
        let seen = BootStageTests.Seen()
        let watch = LogPipeReader.LogWatch(phrases: GuestFaults.watched) { seen.add($0) }
        let bytes = Data(Self.refused.utf8)
        for start in stride(from: 0, to: bytes.count, by: 7) { watch.scan(bytes[start..<min(start + 7, bytes.count)]) }
        let phrases = Set(seen.phrases)
        #expect(phrases == ["Invalid content in Journal", GuestFaults.systemMounted, "fwexec(mount_tool"])
        #expect(GuestFaults.dataVolumeFault(seen: phrases, dataVolume: true) != nil)
        #expect(GuestFaults.dataVolumeFault(seen: phrases, dataVolume: false) == nil)
        #expect(
            GuestFaults.dataVolumeFault(seen: phrases.union([GuestFaults.dataMounted]), dataVolume: true) == nil
        )
    }
}
