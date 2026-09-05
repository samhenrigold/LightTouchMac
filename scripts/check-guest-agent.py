#!/usr/bin/env python3
"""Exercise the production actor against a controllable local C transport."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'LightTouchMac/DeviceTools.swift').read_text()
actor=s[s.index('private actor GuestAgentTransport'):]
header='''#include <stdbool.h>
bool qemu_ios_agent_request(const char *);
char *qemu_ios_agent_result(void);
void qemu_ios_agent_free_result(char *);
void qemu_ios_agent_cancel(const char *);
int qemu_ios_agent_status(void);
bool qemu_ios_ui_ready(void);
int cancellations(void);
void unavailable(void);
'''
c=r'''
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdbool.h>
static char *queue[16];static int count,cancelled,alive=1,delay;
bool qemu_ios_agent_request(const char *s) {
 char id[64];sscanf(s,"%63s",id);
 if (strstr(s,"never")) return true;
 char out[128];snprintf(out,sizeof(out),"%s 0\nb2s=",id);
 queue[count++]=strdup(out);delay=1;return true;
}
char *qemu_ios_agent_result(void) {
 if(delay){delay=0;return NULL;}
 return count?queue[--count]:NULL;
}
void qemu_ios_agent_free_result(char *p){free(p);}
void qemu_ios_agent_cancel(const char *s){cancelled++;}
int qemu_ios_agent_status(void){return alive;}
bool qemu_ios_ui_ready(void){return true;}
int cancellations(void){return cancelled;}
void unavailable(void){alive=0;}
'''
swift='''import Foundation
enum DeviceToolsError: Error { case failed(String) }
'''+actor+'''
@main struct Check {
 static func main() async throws {
   async let a = GuestAgentTransport.shared.runIfAvailable("first", stdinPath: nil)
   async let b = GuestAgentTransport.shared.runIfAvailable("second", stdinPath: nil)
   let values = try await [a,b]
   precondition(values.allSatisfy { $0 == Data("ok".utf8) })
   let task = Task { try await GuestAgentTransport.shared.runIfAvailable("never", stdinPath: nil) }
   try await Task.sleep(for: .milliseconds(30))
   task.cancel()
   do { _ = try await task.value; fatalError("cancellation ignored") }
   catch is CancellationError { }
   precondition(cancellations() == 1)
   unavailable()
   let fallback = try await GuestAgentTransport.shared.runIfAvailable("first", stdinPath: nil)
   precondition(fallback == nil)
   print("PASS: concurrent result routing, cancellation, absent-agent fallback")
 }
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'shim.h').write_text(header);(p/'shim.c').write_text(c);(p/'check.swift').write_text(swift)
 subprocess.run(['clang','-c',str(p/'shim.c'),'-o',str(p/'shim.o')],check=True)
 subprocess.run(['swiftc','-module-cache-path',str(p/'cache'),'-swift-version','6','-parse-as-library','-import-objc-header',str(p/'shim.h'),str(p/'check.swift'),str(p/'shim.o'),'-o',str(p/'check')],check=True)
 subprocess.run([str(p/'check')],check=True)
