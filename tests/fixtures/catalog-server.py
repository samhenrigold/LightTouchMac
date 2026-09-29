#!/usr/bin/env python3
"""Small local HTTP fixture for the real CatalogClient and AppKit sheet checks."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib, json, sys, time
from urllib.parse import urlparse, parse_qs

BODY = b'catalog download fixture\n' * 4096
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        path = urlparse(self.path)
        origin = 'http://127.0.0.1:' + str(self.server.server_port)
        ident = parse_qs(path.query).get('ipa_id', ['123'])[0]
        def app(i):
            return dict(name='Fixture App', bundle_id='test.fixture', developer='Fixture', version='1.0', min_os='3.0',
                        size=len(BODY), ipa_id=int(i), download_url=origin+'/ipa/'+i, app_url=origin+'/app/test.fixture')
        if path.path == '/api/emulator/apps':
            if ident == '999':
                self.send_error(503);return
            data = {'apps': [app(ident)]}
        elif path.path.startswith('/api/v1/copies/'):
            ident=path.path.rsplit('/',1)[1]
            if ident=='123':time.sleep(.2)
            data=dict(ipa_id=ident, filename='fixture-'+ident+'.ipa',size=len(BODY),
                      md5=hashlib.md5(BODY).hexdigest() if ident!='666' else '0'*32,available=True,
                      version='1.0' if ident=='123' else '0.9',bundle_id='test.fixture',
                      binary=dict(install_status='installable',architectures=['armv6'],macho_min_os='3.0',device_family_macho=['1']))
        elif path.path.endswith('/versions'):
            data={'data':[dict(version=v,minimum_os_version='3.0',copies=[dict(ipa_id=i,size=len(BODY),install_status='installable',architectures=['armv6'],macho_min_os='3.0')]) for i,v in [('123','1.0'),('456','0.9')]]}
        elif path.path.startswith('/ipa/'):
            self.send_response(200);self.send_header('Content-Length',str(len(BODY)));self.end_headers()
            try:
                for i in range(0,len(BODY),4096):
                    self.wfile.write(BODY[i:i+4096]);self.wfile.flush()
                    if path.path.endswith('/777'):time.sleep(.05)
            except (BrokenPipeError,ConnectionResetError):pass
            return
        else:self.send_error(404);return
        body=json.dumps(data).encode();self.send_response(200);self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(body)));self.end_headers()
        try:self.wfile.write(body)
        except BrokenPipeError:pass

if __name__=='__main__':
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    open(sys.argv[1],'w').write(str(server.server_port))
    server.serve_forever()
