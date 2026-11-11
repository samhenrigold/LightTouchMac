import Foundation
import Testing

@testable import LightTouchCore

/// A crash's call stack summed up as the crashed thread's top frame and its first in the app, binary+offset only.
struct CrashSummaryTests {
    /// Two threads, the second crashed: its top frame is in libsystem, its first app frame two callers down.
    @Test func crashedThreadsTopFrameAndFirstAppFrame() {
        let tree = Data(
            #"""
            {"callStackPerThread":true,"callStacks":[
              {"threadAttributed":false,"callStackRootFrames":[{"binaryName":"LightTouch","offsetIntoBinaryTextSegment":16}]},
              {"threadAttributed":true,"callStackRootFrames":[
                {"binaryName":"libsystem_kernel.dylib","offsetIntoBinaryTextSegment":4660,"address":1,"subFrames":[
                  {"binaryName":"AppKit","offsetIntoBinaryTextSegment":255,"subFrames":[
                    {"binaryName":"LightTouch","offsetIntoBinaryTextSegment":43981,"subFrames":[
                      {"binaryName":"LightTouch","offsetIntoBinaryTextSegment":1}]}]}]}]}]}
            """#.utf8
        )
        #expect(
            CrashSummary.frames(callStackTree: tree, binary: "LightTouch")
                == ["frame": "libsystem_kernel.dylib+0x1234", "appFrame": "LightTouch+0xabcd"]
        )
    }

    @Test func noAppFrameOrNoTree() {
        let tree = Data(
            #"{"callStacks":[{"callStackRootFrames":[{"binaryName":"dyld","offsetIntoBinaryTextSegment":8}]}]}"#.utf8
        )
        #expect(CrashSummary.frames(callStackTree: tree, binary: "LightTouch") == ["frame": "dyld+0x8"])
        #expect(CrashSummary.frames(callStackTree: Data("[]".utf8), binary: "LightTouch").isEmpty)
    }

    /// The helper's crash report: thread 1 faulted in libsystem, called from QEMU; its paths and key stay out.
    @Test func helperCrashReportsFaultingThread() {
        let ips = Data(
            #"""
            {"app_name":"LightTouchDevice","bug_type":"309"}
            {"crashReporterKey":"SECRET","procName":"LightTouchDevice",
             "procPath":"/Users/someone/Light Touch.app/Contents/MacOS/LightTouchDevice",
             "exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"faultingThread":1,
             "threads":[{"frames":[{"imageOffset":1,"imageIndex":0}]},
               {"frames":[{"imageOffset":4096,"symbol":"_platform_memmove","imageIndex":2},
                          {"imageOffset":43981,"imageIndex":1},{"imageOffset":2,"imageIndex":0}]}],
             "usedImages":[{"name":"LightTouchDevice","path":"/Users/someone/x"},{"name":"libqemu-arm.dylib"},
                           {"name":"libsystem_platform.dylib"}]}
            """#.utf8
        )
        let summary = CrashSummary.report(ips: ips, ours: ["LightTouchDevice", "libqemu-arm.dylib"])
        #expect(
            summary == [
                "process": "LightTouchDevice", "exceptionType": "EXC_BAD_ACCESS", "signal": "SIGSEGV",
                "frame": "libsystem_platform.dylib+0x1000 _platform_memmove", "appFrame": "libqemu-arm.dylib+0xabcd"
            ]
        )
        #expect(!summary.values.contains { $0.contains("someone") || $0.contains("SECRET") })
        #expect(CrashSummary.report(ips: Data("{}".utf8), ours: []).isEmpty)
    }

    /// An uncaught exception's report: its backtrace names where it was thrown, not the abort that followed.
    @Test func uncaughtExceptionUsesItsBacktrace() {
        let ips = Data(
            #"""
            {"app_name":"Light Touch"}
            {"procName":"LightTouch","exception":{"type":"EXC_CRASH","signal":"SIGABRT"},"faultingThread":0,
             "threads":[{"frames":[{"imageOffset":1,"symbol":"__pthread_kill","imageIndex":1}]}],
             "lastExceptionBacktrace":[{"imageOffset":16,"symbol":"__exceptionPreprocess","imageIndex":1},
                                       {"imageOffset":255,"imageIndex":0}],
             "usedImages":[{"name":"LightTouch"},{"name":"CoreFoundation"}]}
            """#.utf8
        )
        let summary = CrashSummary.report(ips: ips, ours: ["LightTouch"])
        #expect(summary["frame"] == "CoreFoundation+0x10 __exceptionPreprocess")
        #expect(summary["appFrame"] == "LightTouch+0xff")
    }
}
