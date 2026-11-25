"""zx-vvv's network test site (M5): run it on a PC, browse it from the 48K.

    python apps/zx-vvv/host/testsite.py [port]          (default 8080)

It prints the address to type into zx-vvv (G): http://<this PC>:<port>/.
The modem must be on the same network; Windows may ask once whether to
let Python accept connections.

The home page lists every case as a link with the expected result next
to it. Each page that loads says which case it is and its own path, so
you can check that redirects and relative links arrived in the right
place. Every request is logged here, with what was sent back.

Cases: content types (shown or refused), redirects (each kind, relative
and absolute Location, the 5-redirect limit), error statuses with a body,
UTF-8 that the modem turns into ASCII, chunked and connection-close
bodies, a page bigger than zx-vvv's buffer, a server too slow to answer,
unreachable hosts, and relative links of every form. Forms (M8): the form
test pages from apps/zx-vvv/testpages, and the spec's guestbook example if
the spec package is there.
"""
import os
import socket
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
HERE = os.path.dirname(os.path.abspath(__file__))
FORM_PAGES = {                          # served at /forms/<name>
    'fields.8tml': os.path.join(HERE, '..', 'testpages', 'fields.8tml'),
    'form.8tml': os.path.join(HERE, '..', 'testpages', 'form.8tml'),
    'guestbook.8tml': os.path.join(HERE, '..', 'spec', 'spec', 'examples', 'guestbook.8tml'),
}


def page(title, *lines):
    return ('---\n8tml: 1\ntitle: ' + title + '\ncase: mixed\n---\n' + '\n'.join(lines) + '\n').encode()


def landed(name, path, note=''):
    """A target page: says which case it is and where it is."""
    return page(name, '# ' + name, '', 'PASS if you can read this.', '',
                'This page is ' + path + '.', *([note] if note else []), '',
                '[Back to the test site](/index.8tml)')


HOME = page(
    'zx-vvv tests',
    '# zx-vvv network tests',
    '',
    'Follow each link. The expected result is after it; B comes back.',
    '',
    '[Content types](/types.8tml)',
    '[Redirects](/redirects.8tml)',
    '[Errors and odd servers](/errors.8tml)',
    '[Relative links](/dir/index.8tml)',
    '[Forms](/forms/index.8tml)',
)

FORMS = page(
    'Forms',
    '# Forms (M8)',
    '',
    'Each page should look like the 8TML reference draws it. 6/7 move',
    'over links and fields; a field shows as [type] name below.',
    '',
    '* [Every field](fields.8tml): every type, odd options, 2 screens',
    '* [A small form](form.8tml): a text field and a button',
    "* [The spec's guestbook](guestbook.8tml): if the spec is here",
    '',
    '[Home](/index.8tml)',
)

TYPES = page(
    'Content types',
    '# Content types',
    '',
    '* [text/8tml](/t/8tml.8tml): shown',
    '* [text/plain](/t/plain): shown as plain text',
    '* [octet-stream](/t/octet): shown',
    '* [no type at all](/t/none): shown',
    '* [text/html](/t/html): "Unsupported type", page stays',
    '* [an image](/t/png): "Unsupported type", page stays',
    '* [a font](/t/font): "Unsupported type", page stays',
    '* [UTF-8 accents](/t/utf8.8tml): letters without accents',
    '',
    '[Home](/index.8tml)',
)

REDIRECTS = page(
    'Redirects',
    '# Redirects',
    '',
    'Each one lands on a page that names it.',
    '',
    '* [301, absolute Location](/r/301)',
    '* [302, relative Location](/r/302)',
    '* [303](/r/303)',
    '* [307](/r/307)',
    '* [308](/r/308)',
    '* [5 in a row](/r/chain/5): lands (the limit)',
    '* [6 in a row](/r/chain/6): "Too many redirects"',
    '* [http to this site, then a relative link](/r/rel): the',
    '  relative link on the target works',
    '',
    '[Home](/index.8tml)',
)

ERRORS = page(
    'Errors',
    '# Errors and odd servers',
    '',
    '* [404 with a page](/e/404): the page, "HTTP 404"',
    '* [500, plain text](/e/500): the text, "HTTP 500"',
    '* [chunked body](/e/chunked): shown in full',
    '* [body ends at close](/e/close): shown in full',
    '* [a page too big](/e/big): "Page cut"',
    '* [a slow server (40 s)](/e/slow): "Timed out" after',
    '  30 s, page stays',
    '* [a host that does not exist](http://nonexistent.invalid/): "Could not connect"',
    '* [a closed port](/e/closedport): "Could not connect"',
    '',
    '[Home](/index.8tml)',
)

DIR = page(
    'Relative links',
    '# Relative links',
    '',
    'This page is /dir/index.8tml. Each link should land as said.',
    '',
    '* [a.8tml](a.8tml): /dir/a.8tml',
    '* [../up.8tml](../up.8tml): /up.8tml',
    '* [../../../up.8tml](../../../up.8tml): /up.8tml (not above',
    '  the root)',
    '* [/abs.8tml](/abs.8tml): /abs.8tml',
    '* [sub/](sub/): /dir/sub/index.8tml',
    '* [?q=1](?q=1): this page, with ?q=1',
    '* [#top](#top): the top of this page, no loading',
    '* [./b.8tml#part](./b.8tml#part): /dir/b.8tml, at its',
    '  top (8TML has no anchors: #part is dropped)',
    '* [mailto:x@example.com](mailto:x@example.com): "Can\'t follow',
    '  this link"',
    '',
    '[Home](/index.8tml)',
)

UTF8 = ('---\n8tml: 1\ntitle: UTF-8\ncase: mixed\n---\n# UTF-8\n\n'
        'Hungarian: árvíztűrő tükörfúrógép\n\n'
        'ÁRVÍZTŰRŐ TÜKÖRFÚRÓGÉP\n\n'
        '“Curly quotes”, ‘single’, en – and em — dashes, an ellipsis…\n\n'
        'PASS if every letter shows without accents.\n\n'
        '[Back](/types.8tml)\n').encode('utf-8')


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def send(self, status, body, ctype='text/8tml', headers=()):
        self.send_response(status)
        if ctype:
            self.send_header('Content-Type', ctype)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.note = f'{status} {ctype or "no type"} {len(body)} bytes'

    def redirect(self, status, location):
        self.send(status, b'', None, [('Location', location)])
        self.note = f'{status} -> {location}'

    def do_GET(self):
        self.note = ''
        u = urlsplit(self.path)
        p = u.path
        host = self.headers.get('Host', f'localhost:{PORT}')
        if p in ('/', '/index.8tml'):
            self.send(200, HOME)
        elif p in ('/forms/', '/forms/index.8tml'):
            self.send(200, FORMS)
        elif p.startswith('/forms/') and p[7:] in FORM_PAGES:
            try:
                with open(FORM_PAGES[p[7:]], 'rb') as f:
                    self.send(200, f.read())
            except OSError:
                self.send(404, page('Not here', '# Not here', '', 'That page is not on this PC.',
                                    '', '[Forms](/forms/index.8tml)'))
        elif p == '/types.8tml':
            self.send(200, TYPES)
        elif p == '/redirects.8tml':
            self.send(200, REDIRECTS)
        elif p == '/errors.8tml':
            self.send(200, ERRORS)
        elif p in ('/dir/', '/dir/index.8tml'):
            self.send(200, DIR.replace(b'This page is /dir/index.8tml.',
                                       ('This page is ' + self.path + '.').encode()))
        elif p == '/dir/b.8tml':
            self.send(200, landed('Relative link', self.path,
                                  'From ./b.8tml#part: PASS if the path above has no #part '
                                  '(zx-vvv drops it, 8TML has no anchors) and you are at the top.'))
        elif p.startswith('/dir/') or p in ('/up.8tml', '/abs.8tml'):
            self.send(200, landed('Relative link', self.path))
        # content types
        elif p == '/t/8tml.8tml':
            self.send(200, landed('text/8tml', p))
        elif p == '/t/plain':
            self.send(200, b'Plain text, *no markup*, PASS if you can read this.\n', 'text/plain; charset=utf-8')
        elif p == '/t/octet':
            self.send(200, landed('octet-stream', p), 'application/octet-stream')
        elif p == '/t/none':
            self.send(200, landed('no content type', p), None)
        elif p == '/t/html':
            self.send(200, b'<html><body>FAIL: HTML must be refused</body></html>', 'text/html; charset=utf-8')
        elif p == '/t/png':
            self.send(200, b'\x89PNG\r\n\x1a\nFAIL', 'image/png')
        elif p == '/t/font':
            self.send(200, b'wOFF FAIL', 'font/woff')
        elif p == '/t/utf8.8tml':
            self.send(200, UTF8, 'text/8tml; charset=utf-8')
        # redirects
        elif p == '/r/301':
            self.redirect(301, f'http://{host}/r/done?301')
        elif p == '/r/302':
            self.redirect(302, 'done?302')
        elif p in ('/r/303', '/r/307', '/r/308'):
            self.redirect(int(p[3:]), f'/r/done?{p[3:]}')
        elif p.startswith('/r/chain/'):
            n = int(p.rsplit('/', 1)[1])
            self.redirect(302, f'/r/chain/{n - 1}' if n > 1 else '/r/done?chain')
        elif p == '/r/rel':
            self.redirect(301, '/dir/index.8tml')
        elif p == '/r/done':
            self.send(200, landed('Redirect: ' + (u.query or '?'), self.path))
        # errors and odd servers
        elif p == '/e/404':
            self.send(404, landed('Not found', p, 'Expect "Server says HTTP 404".'))
        elif p == '/e/500':
            self.send(500, b'Server error 500, PASS if you can read this.\n', 'text/plain')
        elif p == '/e/chunked':
            body = landed('Chunked', p, 'Sent in 4 chunks.')
            self.send_response(200)
            self.send_header('Content-Type', 'text/8tml')
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            for i in range(0, len(body), len(body) // 4 + 1):
                part = body[i:i + len(body) // 4 + 1]
                self.wfile.write(b'%x\r\n%s\r\n' % (len(part), part))
            self.wfile.write(b'0\r\n\r\n')
            self.note = 'chunked'
        elif p == '/e/close':
            body = landed('Body to close', p, 'No length: the body ends when the server closes.')
            self.send_response(200)
            self.send_header('Content-Type', 'text/8tml')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(body)
            self.close_connection = True
            self.note = 'body ended by close'
        elif p == '/e/big':
            lines = [f'Line {i:05d} of a page that is too big for the buffer.' for i in range(500)]
            self.send(200, page('Too big', '# Too big', '', 'Expect "Page cut".', '', *lines))
        elif p == '/e/slow':
            time.sleep(40)
            self.send(200, landed('Slow', p, 'FAIL: the modem should have given up.'))
        elif p == '/e/closedport':
            self.redirect(302, f'http://{host.split(":")[0]}:1/')
        else:
            self.send(404, landed('Unknown page', self.path, 'FAIL: no such test page.'))

    def log_message(self, fmt, *args):
        sys.stdout.write(f'{self.client_address[0]}  {self.requestline}  ->  {getattr(self, "note", "")}\n')


def my_address():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('192.0.2.1', 80))            # no packet is sent
        return s.getsockname()[0]
    except OSError:
        return '127.0.0.1'
    finally:
        s.close()


if __name__ == '__main__':
    server = ThreadingHTTPServer(('', PORT), Handler)
    print(f'zx-vvv test site: on the Spectrum, G and type  {my_address()}:{PORT}')
    print('(Ctrl+C stops it)')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
