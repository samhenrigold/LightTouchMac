#!/usr/bin/env python3
"""Preserve Safari's request and the origin's status through the native proxy."""
from pathlib import Path
import http.server, subprocess, sys, tempfile, threading
root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / 'scripts'))
import sources  # the pinned checkouts (build-support/sources.json)
source = sources.path('qemu-ios') / 'contrib/it-webproxy/itwebproxy.c'
legacy_agent = ('Mozilla/5.0 (iPod; U; CPU iPhone OS 3_1_3 like Mac OS X; en-us) '
                'AppleWebKit/528.18 (KHTML, like Gecko) Version/4.0 Mobile/7E18 Safari/528.16')
requests = []
class Origin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append((self.path, self.headers.get('User-Agent')))
        blocked = self.headers.get('User-Agent') == legacy_agent
        body = b'Legacy client rejected by origin' if blocked else b'Origin accepted request'
        self.send_response(403 if blocked else 200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_):
        pass
with tempfile.TemporaryDirectory(prefix='ltm-proxy-forwarding-') as directory:
    work = Path(directory)
    binary = work/'proxy'
    subprocess.run(['cc', '-g', '-fsanitize=address,undefined', '-Wno-deprecated-declarations',
                    str(source), '-lcurl', '-o', str(binary)], check=True)
    config = work/'routing'; config.write_text('direct\n')
    origin = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Origin)
    thread = threading.Thread(target=origin.serve_forever, daemon=True); thread.start()
    try:
        path = '/search?q=light+touch&ie=UTF-8&oe=UTF-8&client=safari'
        for agent, status, body in [(legacy_agent, b'403', b'Legacy client rejected by origin'),
                                    ('Fixture Browser', b'200', b'Origin accepted request')]:
            request = (f'GET http://127.0.0.1:{origin.server_port}{path} HTTP/1.1\r\n'
                       f'User-Agent: {agent}\r\nHost: www.google.com\r\n\r\n').encode()
            result = subprocess.run([str(binary), str(config)], input=request,
                                    capture_output=True, timeout=10)
            assert result.returncode == 0, result.stderr
            head, actual_body = result.stdout.split(b'\r\n\r\n', 1)
            assert head.split(b' ', 2)[1] == status, head
            assert actual_body == body, actual_body
            assert requests[-1] == (path, agent), requests
    finally:
        origin.shutdown(); origin.server_close(); thread.join()
print('PASS: native proxy preserves legacy Safari URL, user agent, origin 403 and successful responses')
