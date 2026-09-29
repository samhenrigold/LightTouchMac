#!/usr/bin/env python3
"""The helper's web proxy (LightTouchDevice/WebProxy.swift) end to end against loopback origins, no network:
HTTP forwarding and framing, CONNECT terminated as TLS 1.0 with a leaf from the device's CA (the guest's view)
and fetched over verified TLS (the Mac's view), URLCache hits, off mode's raw pass-through, archive replay
(redirects, text links, privacy, cooldown, cache), the location and Weather answers' framing, the CA files
(the old itwebproxy's format: concurrent creation, owner-only key), and the adapters' own checks."""
import concurrent.futures, gzip, http.server, os, plistlib, socket, ssl, subprocess, sys, tempfile, threading, time, warnings
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [ROOT / 'LightTouchDevice/WebProxy.swift', ROOT / 'LightTouchDevice/WebProxyAdapters.swift',
           ROOT / 'Shared/WebProxyCA.swift', ROOT / 'tests/drivers/web-proxy/main.swift']
LOCATION = bytes.fromhex('00010005656e5f55530000000b332e322e322e3742353030000000010000001f'
                         '0a080800100018002000120f0a0d323a303a35653a31303a303a3118002000')


def build(work):
    exe = work / 'web-proxy'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(work / 'modules'), *map(str, SOURCES),
                    '-o', str(exe)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return exe


class Origin(http.server.BaseHTTPRequestHandler):
    """The origin, and the archive (paths under /web/)."""
    counts = {}
    seen = {}

    def reply(self, status, body=b'', headers=()):
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        if not any(name == 'Transfer-Encoding' for name, _ in headers):
            self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path
        Origin.counts[path] = Origin.counts.get(path, 0) + 1
        Origin.seen[path] = dict(self.headers)
        if path.startswith('/web/'):
            if path.endswith('/limited'):
                return self.reply(429, headers=[('Retry-After', '120')])
            if path.endswith('/secure-redirect'):
                return self.reply(302, headers=[('Location', 'https://example.invalid/secure-page')])
            if path.endswith('/secure-page'):
                return self.reply(200, gzip.compress(b'<a href="https://example.invalid/next">next</a>'),
                                  [('Content-Type', 'text/html'), ('Content-Encoding', 'gzip')])
            if path.endswith('/binary'):
                return self.reply(200, b'\0https://untouched\0', [('Content-Type', 'application/octet-stream')])
            if path.startswith('/web/20090909id_/'):
                return self.reply(302, headers=[('Location', path.replace('20090909id_', '20090910000000id_'))])
            assert 'Cookie' not in self.headers and 'Authorization' not in self.headers
            return self.reply(200, b'ARCHIVED ORIGINAL PAGE', [('Set-Cookie', 'archive=must-not-leak'), ('Content-Type', 'text/plain')])
        if path == '/cached':
            return self.reply(200, b'cached %d' % Origin.counts[path], [('Cache-Control', 'max-age=600')])
        if path == '/gzip':
            return self.reply(200, gzip.compress(b'decoded body'), [('Content-Encoding', 'gzip'), ('Content-Type', 'text/plain')])
        if path == '/redirect':
            return self.reply(302, headers=[('Location', '/elsewhere')])
        if path == '/cookies':
            self.send_response(200)
            self.send_header('Set-Cookie', 'a=1; expires=Wed, 09-Jun-2027 10:18:14 GMT; path=/')
            self.send_header('Set-Cookie', 'b=2; path=/')
            self.send_header('Content-Length', '0')
            return self.end_headers()
        if path == '/chunked':
            self.send_response(200)
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            return self.wfile.write(b'5\r\nhello\r\n0\r\n\r\n')
        self.reply(200, b'hello ' + (self.headers.get('Cookie') or '').encode(), [('Content-Type', 'text/plain')])

    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        self.reply(200, body)

    def log_message(self, *_):
        pass


def serve(origin_class, context=None):
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), origin_class)
    if context:
        server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main():
    # The helper has an Info.plist, so ATS would refuse the guest's http:// origins (all but loopback, which this
    # check can't tell apart); its partial Info.plist allows them.
    assert plistlib.loads((ROOT / 'Configuration/LightTouchDevice-Info.plist').read_bytes())['NSAppTransportSecurity']['NSAllowsArbitraryLoads']
    assert (ROOT / 'LightTouchMac.xcodeproj/project.pbxproj').read_text().count('INFOPLIST_FILE = "Configuration/LightTouchDevice-Info.plist";') == 2
    with tempfile.TemporaryDirectory(prefix='ltm-wp-') as directory:
        work = Path(directory)
        exe = build(work)
        subprocess.run([exe, 'adapters'], check=True)
        config = work / 'web-proxy.conf'
        config.write_text('direct\n')

        # The CA: created once under concurrent callers, the key owner-only; an open key is refused.
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            assert all(r.returncode == 0 for r in pool.map(lambda _: subprocess.run([exe, 'init-ca', config]), range(4)))
        der = Path(f'{config}.ca.der').read_bytes()
        subprocess.run([exe, 'init-ca', config], check=True)
        assert Path(f'{config}.ca.der').read_bytes() == der
        assert Path(f'{config}.ca.pem').stat().st_mode & 0o777 == 0o600
        Path(f'{config}.ca.pem').chmod(0o644)
        assert subprocess.run([exe, 'init-ca', config], stdout=subprocess.DEVNULL).returncode != 0
        Path(f'{config}.ca.pem').chmod(0o600)
        ca_pem = ssl.DER_cert_to_PEM_cert(der)

        # A loopback HTTPS origin whose certificate only the proxy's extra root trusts.
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '30', '-subj', '/CN=127.0.0.1',
                        '-addext', 'subjectAltName=IP:127.0.0.1', '-addext', 'extendedKeyUsage=serverAuth',
                        '-keyout', work / 'origin.key', '-out', work / 'origin.pem'], check=True, capture_output=True)
        subprocess.run(['openssl', 'x509', '-in', work / 'origin.pem', '-outform', 'der', '-out', work / 'origin.der'], check=True)
        tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls_context.load_cert_chain(work / 'origin.pem', work / 'origin.key')
        origin, secure_origin = serve(Origin), serve(Origin, tls_context)
        port, secure_port = origin.server_port, secure_origin.server_port

        sock = str(work / 'proxy.sock')
        proxy = subprocess.Popen([exe, 'serve', config, sock, f'http://127.0.0.1:{port}', work / 'origin.der'],
                                 stdout=subprocess.PIPE, text=True)
        assert proxy.stdout.readline().strip() == 'listening'
        untrusting_sock = str(work / 'plain.sock')
        untrusting = subprocess.Popen([exe, 'serve', config, untrusting_sock], stdout=subprocess.PIPE, text=True)
        assert untrusting.stdout.readline().strip() == 'listening'
        assert os.stat(sock).st_mode & 0o777 == 0o600
        try:
            def connect(path=sock):
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(30)
                s.connect(path)
                return s

            def request(data, path=sock):
                with connect(path) as s:
                    s.sendall(data)
                    out = bytearray()
                    while part := s.recv(65536):
                        out += part
                    return bytes(out)

            def status(response):
                return response.split(b'\r\n', 1)[0]

            url = f'http://127.0.0.1:{port}'
            # HTTP: status, body, headers; URLSession's decoding undone in the headers; no redirects followed.
            r = request(f'GET {url}/test HTTP/1.1\r\nHost: ignored\r\nCookie: guest=1\r\nProxy-Connection: keep-alive\r\n\r\n'.encode())
            assert status(r) == b'HTTP/1.0 200 OK' and r.endswith(b'\r\n\r\nhello guest=1') and b'Connection: close' in r, r
            assert 'Proxy-Connection' not in Origin.seen['/test'], Origin.seen['/test']
            r = request(f'GET {url}/chunked HTTP/1.0\r\n\r\n'.encode())
            assert r.endswith(b'\r\n\r\nhello') and b'Transfer-Encoding' not in r, r
            r = request(f'GET {url}/gzip HTTP/1.0\r\nAccept-Encoding: gzip\r\n\r\n'.encode())
            assert r.endswith(b'\r\n\r\ndecoded body') and b'Content-Encoding' not in r, r
            r = request(f'GET {url}/redirect HTTP/1.0\r\n\r\n'.encode())
            assert status(r) == b'HTTP/1.0 302 Found' and b'Location: /elsewhere' in r, r
            r = request(f'GET {url}/cookies HTTP/1.0\r\n\r\n'.encode())
            assert r.count(b'Set-Cookie: ') == 2 and b'Set-Cookie: a=1; expires=Wed, 09-Jun-2027 10:18:14 GMT; path=/' in r, r
            r = request(f'POST {url}/echo HTTP/1.0\r\nContent-Length: 4\r\n\r\n'.encode() + b'a\0bc')
            assert r.endswith(b'\r\n\r\na\0bc'), r
            for header, code in [('Content-Length: 1\r\nContent-Length: 1', b'400'), ('Content-Length: -1', b'400'),
                                 ('Content-Length: 9000000', b'413'), ('Transfer-Encoding: chunked', b'501'),
                                 ('Expect: 100-continue', b'417')]:
                assert code in status(request(f'POST {url}/ HTTP/1.1\r\n{header}\r\n\r\n'.encode())), header
            assert b'431' in status(request(b'GET / HTTP/1.0\r\nX: ' + b'a' * 65536))
            assert b'400' in status(request(b'GET /relative HTTP/1.0\r\n\r\n'))
            for host in ['api.openfeint.com', 'GDATA.YOUTUBE.COM.']:
                assert status(request(f'GET http://{host}/ HTTP/1.0\r\n\r\n'.encode())).startswith(b'HTTP/1.0 410 ')
                assert status(request(f'CONNECT {host}:443 HTTP/1.0\r\n\r\n'.encode())).startswith(b'HTTP/1.0 410 ')
            refused = socket.socket()
            refused.bind(('127.0.0.1', 0))
            assert status(request(f'GET http://127.0.0.1:{refused.getsockname()[1]}/ HTTP/1.0\r\n\r\n'.encode())).startswith(b'HTTP/1.0 502 ')
            refused.close()
            # The guestfwd's transport (WebProxyConfiguration.guestForward): nc on the guest connection's stdin/stdout.
            r = subprocess.run(['/usr/bin/nc', '-U', sock], input=f'GET {url}/test HTTP/1.0\r\n\r\n'.encode(), capture_output=True, timeout=20)
            assert r.stdout.startswith(b'HTTP/1.0 200 OK') and r.stdout.endswith(b'hello '), r
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                assert all(r.endswith(b'hello ') for r in pool.map(lambda _: request(f'GET {url}/many HTTP/1.0\r\n\r\n'.encode()), range(24)))

            # URLCache: a fresh response is served again without the origin; the guest's no-cache reloads.
            first = request(f'GET {url}/cached HTTP/1.0\r\n\r\n'.encode())
            assert request(f'GET {url}/cached HTTP/1.0\r\n\r\n'.encode()).endswith(b'cached 1') and first.endswith(b'cached 1')
            assert Origin.counts['/cached'] == 1, Origin.counts
            assert request(f'GET {url}/cached HTTP/1.0\r\nPragma: no-cache\r\n\r\n'.encode()).endswith(b'cached 2')
            assert any((work / 'web-proxy.conf.cache').rglob('*')), 'the per-device cache lives beside CONFIG'

            # Location (origin-form, as 3.2's locationd sends it) and Weather's framing, without a fetch.
            r = request(b'POST /clls/wloc HTTP/1.1\r\nHost: 10.0.2.100:3128\r\nContent-Length: %d\r\n\r\n' % len(LOCATION) + LOCATION)
            assert status(r) == b'HTTP/1.0 200 OK' and b'application/x-protobuf' in r and r.split(b'\r\n\r\n', 1)[1][:2] == b'\0\1', r
            body = b"<request><query type='getlocationid'><phrase>Q</phrase></query></request>"
            r = request(b'POST http://iphone-wu.apple.com/dgw?apptype=weather HTTP/1.0\r\nContent-Length: %d\r\n\r\n' % len(body) + body)
            head, content = r.split(b'\r\n\r\n', 1)
            assert head.startswith(b'HTTP/1.0 200 OK') and b'Content-Length: %d' % len(content) in head and b'<response>' in content, r

            # CONNECT: TLS 1.0 / AES128-SHA toward the guest, a leaf for the host from the device's CA.
            def tunnel(target, data, trust=True, hostname='127.0.0.1', path=sock):
                s = connect(path)
                s.sendall(f'CONNECT {target} HTTP/1.0\r\n\r\n'.encode())
                header = b''
                while not header.endswith(b'\r\n\r\n'):
                    part = s.recv(1)
                    assert part, header
                    header += part
                assert header.startswith(b'HTTP/1.0 200 '), header
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
                context.set_ciphers('AES128-SHA:@SECLEVEL=0')
                with warnings.catch_warnings():
                    warnings.simplefilter('ignore', DeprecationWarning)
                    context.minimum_version = context.maximum_version = ssl.TLSVersion.TLSv1
                if trust:
                    context.load_verify_locations(cadata=ca_pem)
                with context.wrap_socket(s, server_hostname=hostname) as secure:
                    assert secure.version() == 'TLSv1' and secure.cipher()[0] == 'AES128-SHA', (secure.version(), secure.cipher())
                    leaf = secure.getpeercert(binary_form=True)
                    secure.sendall(data)
                    out = bytearray()
                    while part := secure.recv(16384):
                        out += part
                    return bytes(out), leaf

            target = f'127.0.0.1:{secure_port}'
            r, leaf = tunnel(target, b'GET /test HTTP/1.1\r\nHost: 127.0.0.1\r\nCookie: tls=1\r\n\r\n')
            assert status(r) == b'HTTP/1.0 200 OK' and r.endswith(b'hello tls=1'), r
            text = subprocess.run(['openssl', 'x509', '-inform', 'der', '-noout', '-text'], input=leaf, capture_output=True).stdout.decode()
            assert 'sha1WithRSAEncryption' in text and 'IP Address:127.0.0.1' in text and 'TLS Web Server Authentication' in text \
                and 'CA:FALSE' in text and 'Issuer: CN=Light Touch Device Proxy' in text, text
            for trust, hostname in [(False, '127.0.0.1'), (True, 'wrong.invalid')]:
                try:
                    tunnel(target, b'GET / HTTP/1.0\r\n\r\n', trust, hostname)
                    raise AssertionError('the guest must refuse an untrusted or misnamed certificate')
                except ssl.SSLCertVerificationError:
                    pass
            r, _ = tunnel(target, b'POST / HTTP/1.0\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx')
            assert status(r).startswith(b'HTTP/1.0 400 '), r   # errors go back inside the TLS session
            # Upstream TLS is verified: a proxy without the fixture's root refuses the origin, nothing of it reaches the guest.
            r, _ = tunnel(target, b'GET /test HTTP/1.0\r\n\r\n', path=untrusting_sock)
            assert status(r).startswith(b'HTTP/1.0 502 ') and b'hello' not in r, r

            # Off: stale connections pass straight through; CONNECT is a raw tunnel, half-close included.
            config.write_text('off\n')
            echo = socket.socket()
            echo.bind(('127.0.0.1', 0))
            echo.listen()

            def echo_once():
                c, _ = echo.accept()
                with c:
                    data = bytearray()
                    while part := c.recv(1024):
                        data += part
                    c.sendall(bytes(data))
            t = threading.Thread(target=echo_once)
            t.start()
            with connect() as s:
                s.sendall(f'CONNECT 127.0.0.1:{echo.getsockname()[1]} HTTP/1.0\r\n\r\ntunnel\0bytes'.encode())
                s.shutdown(socket.SHUT_WR)
                out = bytearray()
                while part := s.recv(1024):
                    out += part
            assert bytes(out).endswith(b'\r\n\r\ntunnel\0bytes'), out
            t.join(5)
            t = threading.Thread(target=echo_once)
            t.start()   # the guest's end of input reaches the origin through nc as a half-close
            r = subprocess.run(['/usr/bin/nc', '-U', sock], input=f'CONNECT 127.0.0.1:{echo.getsockname()[1]} HTTP/1.0\r\n\r\nvia nc'.encode(),
                               capture_output=True, timeout=20)
            assert r.stdout.endswith(b'\r\n\r\nvia nc'), r
            t.join(5)
            echo.close()
            with connect() as s:   # the origin's own certificate, not the device CA's
                s.sendall(f'CONNECT {target} HTTP/1.0\r\n\r\n'.encode())
                assert s.recv(4096).startswith(b'HTTP/1.0 200 ')
                context = ssl.create_default_context(cafile=str(work / 'origin.pem'))
                with context.wrap_socket(s, server_hostname='127.0.0.1') as secure:
                    secure.sendall(b'GET /test HTTP/1.0\r\n\r\n')
                    out = bytearray()
                    try:
                        while part := secure.recv(4096):
                            out += part
                    except OSError:   # the origin closed without close_notify; the tunnel closes behind it
                        pass
                    assert out.endswith(b'hello '), out
            assert request(f'GET {url}/cached HTTP/1.0\r\n\r\n'.encode()).endswith(b'cached 3'), 'off bypasses the cache'
            r = request(b'POST /clls/wloc HTTP/1.1\r\nContent-Length: %d\r\n\r\n' % len(LOCATION) + LOCATION)
            assert status(r) == b'HTTP/1.0 200 OK', 'location answers in every mode'

            # Archive: the closest capture, redirects resolved here, no guest cookies or credentials, text links on http.
            config.write_text('archive\n20090909\n')
            r = request(b'GET http://example.invalid/page HTTP/1.0\r\nCookie: secret=value\r\nAuthorization: Basic secret\r\n\r\n')
            assert r.count(b'HTTP/1.0') == 1 and b'200 Archive response' in r and r.endswith(b'ARCHIVED ORIGINAL PAGE'), r
            assert b'Set-Cookie' not in r, r
            count = sum(Origin.counts.values())
            assert request(b'GET http://example.invalid/page HTTP/1.0\r\n\r\n') == r
            assert sum(Origin.counts.values()) == count, 'a repeated page comes from the cache'
            assert b'405' in status(request(b'POST http://example.invalid/page HTTP/1.0\r\n\r\n'))
            assert b'400' in status(request(b'GET http://name:password@example.invalid/page HTTP/1.0\r\n\r\n'))
            r = request(b'GET http://example.invalid/secure-redirect HTTP/1.0\r\n\r\n')
            assert b'200 Archive response' in r and b'href="http://example.invalid/next"' in r, r
            assert b'Content-Encoding' not in r and b'Content-Length: 46' in r, r
            assert request(b'GET http://example.invalid/binary HTTP/1.0\r\n\r\n').endswith(b'\0https://untouched\0')
            r = request(b'GET http://example.invalid/limited HTTP/1.0\r\n\r\n')
            assert b'429' in status(r) and b'Retry-After: 120' in r and b'Light Touch has paused' in r, r
            count = sum(Origin.counts.values())
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                assert all(b'429' in status(x) for x in pool.map(lambda _: request(b'GET http://example.invalid/other HTTP/1.0\r\n\r\n'), range(8)))
            assert sum(Origin.counts.values()) == count, 'the cooldown covers every connection'
            assert request(b'GET http://example.invalid/page HTTP/1.0\r\n\r\n').endswith(b'ARCHIVED ORIGINAL PAGE'), 'cached pages survive the cooldown'
            config.write_text('archive\ninvalid\n')
            assert b'503' in status(request(b'GET http://example.invalid/ HTTP/1.0\r\n\r\n'))
            config.unlink()
            assert b'503' in status(request(b'GET http://example.invalid/ HTTP/1.0\r\n\r\n')), 'no routing: fail closed'
        finally:
            proxy.kill()
            untrusting.kill()
            origin.shutdown()
            secure_origin.shutdown()
    print('PASS: HTTP forwarding and framing, TLS 1.0 CONNECT with per-host leaves, verified upstream TLS, URLCache hits, '
          'off pass-through, archive replay/cooldown/cache, location and Weather framing, CA files')


if __name__ == '__main__':
    main()
