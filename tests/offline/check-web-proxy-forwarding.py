#!/usr/bin/env python3
"""Preserve Safari's request and the origin's status through the helper's web proxy (docs/archive/Proxy-compatibility.md:
Google's 403 for iOS 3 Safari is the origin's own answer, passed on unchanged, never worked around)."""
from pathlib import Path
import http.server, importlib.util, socket, subprocess, tempfile, threading
spec = importlib.util.spec_from_file_location('check_web_proxy', Path(__file__).with_name('check-web-proxy.py'))
proxy_check = importlib.util.module_from_spec(spec); spec.loader.exec_module(proxy_check)
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
with tempfile.TemporaryDirectory(prefix='ltm-wpf-') as directory:
    work = Path(directory)
    binary = proxy_check.build(work)
    config = work/'routing'; config.write_text('direct\n')
    origin = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Origin)
    thread = threading.Thread(target=origin.serve_forever, daemon=True); thread.start()
    proxy = subprocess.Popen([binary, 'serve', config, work/'s'], stdout=subprocess.PIPE, text=True)
    try:
        assert proxy.stdout.readline().strip() == 'listening'
        path = '/search?q=light+touch&ie=UTF-8&oe=UTF-8&client=safari'
        for agent, status, body in [(legacy_agent, b'403', b'Legacy client rejected by origin'),
                                    ('Fixture Browser', b'200', b'Origin accepted request')]:
            with socket.socket(socket.AF_UNIX) as s:
                s.settimeout(20); s.connect(str(work/'s'))
                s.sendall((f'GET http://127.0.0.1:{origin.server_port}{path} HTTP/1.1\r\n'
                           f'User-Agent: {agent}\r\nHost: www.google.com\r\n\r\n').encode())
                response = bytearray()
                while part := s.recv(65536): response += part
            head, actual_body = bytes(response).split(b'\r\n\r\n', 1)
            assert head.split(b' ', 2)[1] == status, head
            assert actual_body == body, actual_body
            assert requests[-1] == (path, agent), requests
    finally:
        proxy.kill(); origin.shutdown(); origin.server_close(); thread.join()
print('PASS: the web proxy preserves legacy Safari URL, user agent, origin 403 and successful responses')
