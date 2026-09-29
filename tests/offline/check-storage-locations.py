#!/usr/bin/env python3
"""Exercise the production state/log layout, its isolation, and the bounded native pipes.
All state and simulated Library directories are temporary fixtures.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='ltm-storage-locations-') as temporary:
    work = Path(temporary)
    source = work / 'check.swift'
    source.write_text(r'''
import Foundation

@main struct Check {
    static func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    static func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    static func denied(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Expected a storage failure") } catch {}
    }
    static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let support = root.appendingPathComponent("Library/Application Support", isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let destination = support.appendingPathComponent(StorageLocations.bundleIdentifier, isDirectory: true)
        let layout = try StorageLocations.prepare(applicationSupport:support, library:library)
        precondition(layout.state == destination && exists(destination))
        precondition(layout.logs.path == library.appendingPathComponent("Logs/"+StorageLocations.bundleIdentifier).path && exists(layout.logs))
        for url in [destination, layout.logs] {
            precondition(try fm.attributesOfItem(atPath:url.path)[.posixPermissions] as! NSNumber == 0o700)
        }
        _ = try StorageLocations.prepare(applicationSupport:support, library:library)

        // An isolated run keeps its state and logs under the override.
        let isolated = root.appendingPathComponent("isolated")
        let isolatedLayout = try StorageLocations.prepare(applicationSupport:support, library:library, override:isolated)
        precondition(isolatedLayout.state == isolated && isolatedLayout.logs == isolated.appendingPathComponent("Logs",isDirectory:true))
        // A file where the state directory should be stops startup.
        let blocked = root.appendingPathComponent("blocked")
        try write("keep", blocked)
        denied { _ = try StorageLocations.prepare(applicationSupport:support, library:library, override:blocked) }
        precondition(try text(blocked) == "keep")

        let logs = root.appendingPathComponent("log-tests")
        try StorageLocations.privateDirectory(logs)
        let streamURL = logs.appendingPathComponent("stream.log")
        let capture = try ProcessLogCapture(url:streamURL)
        let writer = FileHandle(fileDescriptor:capture.writeDescriptor,closeOnDealloc:false)
        try writer.write(contentsOf:Data(repeating:65,count:2_300_000))
        capture.flush()
        for path in [streamURL,streamURL.appendingPathExtension("1")] {
            let data=try Data(contentsOf:path)
            precondition(!data.isEmpty && data.count <= StorageLocations.logLimit && data.allSatisfy{$0==65})
            precondition(try fm.attributesOfItem(atPath:path.path)[.posixPermissions] as! NSNumber == 0o600)
        }
        // The general reader must cancel after EOF instead of spinning on a
        // permanently readable closed pipe; subsequent flush/finish are safe.
        var descriptors:[Int32]=[-1,-1]
        precondition(pipe(&descriptors)==0)
        let eofLog=logs.appendingPathComponent("eof.log")
        let reader=try LogPipeReader(descriptor:descriptors[0],log:RotatingLog(url:eofLog))
        let input=FileHandle(fileDescriptor:descriptors[1],closeOnDealloc:false)
        try input.write(contentsOf:Data("EOF marker".utf8));Darwin.close(descriptors[1])
        try await Task.sleep(for:.milliseconds(30))
        reader.flush();reader.finish()
        precondition(try text(eofLog)=="EOF marker")

        let fifoRoot=root.appendingPathComponent("fifo")
        try StorageLocations.privateDirectory(fifoRoot)
        let serial=try SerialLogCapture(url:logs.appendingPathComponent("fifo.log"),temporaryRoot:fifoRoot)
        let fifo=String(serial.argument.dropFirst("pipe:".count))+".out"
        let fd=open(fifo,O_WRONLY);precondition(fd>=0)
        let fifoWriter=FileHandle(fileDescriptor:fd,closeOnDealloc:false)
        try fifoWriter.write(contentsOf:Data("guest serial".utf8));Darwin.close(fd)
        // Unlink during app stop while keeping the writer alive: subsequent
        // native writes remain safe, and normal quit leaves no FIFO names.
        let activeFD=open(fifo,O_WRONLY);precondition(activeFD>=0)
        serial.removeEndpoints()
        precondition(try fm.contentsOfDirectory(atPath:fifoRoot.path).isEmpty)
        let activeWriter=FileHandle(fileDescriptor:activeFD,closeOnDealloc:false)
        try activeWriter.write(contentsOf:Data(" after unlink".utf8));Darwin.close(activeFD)
        serial.finish()
        precondition(try fm.contentsOfDirectory(atPath:fifoRoot.path).isEmpty)
        precondition(try text(logs.appendingPathComponent("fifo.log"))=="guest serial after unlink")

        // App events enter unified logging separately, so stderr capture does
        // not duplicate them in the native file. Restore test runner stdout.
        let savedOut=dup(STDOUT_FILENO), savedErr=dup(STDERR_FILENO)
        try Bundled.requireStorage()
        try NativeLogging.start()
        fputs("native error marker\n",stderr);fputs("native output marker\n",stdout);fflush(stdout)
        logEvent("app event only marker")
        await AppEventLog.shared.flush();NativeLogging.flush()
        precondition(try text(Bundled.logsDirectory.appendingPathComponent("native.log")).contains("native error marker"))
        precondition(try text(Bundled.logsDirectory.appendingPathComponent("native.log")).contains("native output marker"))
        precondition(!(try! text(Bundled.logsDirectory.appendingPathComponent("native.log"))).contains("app event only marker"))
        precondition(try text(Bundled.logsDirectory.appendingPathComponent("app.log")).contains("app event only marker"))
        _=dup2(savedOut,STDOUT_FILENO);_=dup2(savedErr,STDERR_FILENO)
        Darwin.close(savedOut);Darwin.close(savedErr)
        print("PASS: private state/log layout, isolation, a blocked root refused, bounded log streams, EOF and FIFO cleanup, unified/native separation")
    }
}
'''.replace('precondition(try ', 'precondition(try! '))
    subprocess.run(['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor',
                    '-module-cache-path',str(work/'modules'),
                    *[str(root/'LightTouchMac'/name) for name in ['StorageLocations.swift','NativeLogging.swift','Bundled.swift','AppEventLog.swift']],
                    str(source),'-o',str(work/'check')],check=True)
    subprocess.run([str(work/'check'),str(work/'fixtures')],
                   env=dict(os.environ,LTM_STATE_DIR=str(work/'isolated-app')),check=True)
