"""A tiny scripted IRC client for tests/e2e.sh."""
import base64
import hashlib
import os
import re
import socket
import ssl
import struct
import time


class Fail(Exception):
    pass


class Client:
    def __init__(self, port, name, path=None, sock=None):
        self.name = name
        if sock:
            self.sock = sock
            self.sock.settimeout(5)
        elif path:
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.settimeout(5)
            self.sock.connect(path)
        else:
            self.sock = socket.create_connection(("127.0.0.1", port),
                                                 timeout=5)
        self.buf = b""
        self.seen = []

    def send(self, line):
        self.sock.sendall(line.encode() + b"\r\n")

    def _readline(self, deadline):
        while b"\n" not in self.buf:
            left = deadline - time.time()
            if left <= 0:
                return None
            self.sock.settimeout(left)
            try:
                data = self.sock.recv(4096)
            except socket.timeout:
                return None
            if not data:
                raise Fail(f"{self.name}: connection closed")
            self.buf += data
        line, self.buf = self.buf.split(b"\n", 1)
        text = line.decode(errors="replace").rstrip("\r")
        self.seen.append(text)
        return text

    def expect(self, pattern, timeout=10.0):
        """Read lines until one matches the regex; return it."""
        deadline = time.time() + timeout
        rx = re.compile(pattern)
        while True:
            line = self._readline(deadline)
            if line is None:
                raise Fail(f"{self.name}: no line matching {pattern!r}; saw:\n  "
                           + "\n  ".join(self.seen[-25:]))
            if line.startswith("PING"):
                self.send("PONG" + line[4:])
            if rx.search(line):
                return line

    def drain(self, seconds):
        """Collect what arrives for a while."""
        deadline = time.time() + seconds
        out = []
        while True:
            line = self._readline(deadline)
            if line is None:
                return out
            if line.startswith("PING"):
                self.send("PONG" + line[4:])
            out.append(line)

    def register(self, nick, user, password=None, realname="Test"):
        if password:
            self.send(f"PASS {password}")
        self.send(f"NICK {nick}")
        self.send(f"USER {user} 0 * :{realname}")
        return self.expect(r" 001 ")

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def ws_request(port=None, path="/", extra=(), tls=False, unix=None,
               host=None, method="GET"):
    """Open a connection and send a WebSocket handshake; return (socket,
    status line, header dict, key, bytes read after the head)."""
    if unix:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect(unix)
        host = host or "soja.sock"
    else:
        sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        if tls:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            sock = ctx.wrap_socket(sock)
        host = host or f"127.0.0.1:{port}"
    key = base64.b64encode(os.urandom(16)).decode()
    lines = [f"{method} {path} HTTP/1.1", f"Host: {host}",
             "Upgrade: websocket", "Connection: Upgrade",
             f"Sec-WebSocket-Key: {key}", "Sec-WebSocket-Version: 13",
             *extra, "", ""]
    sock.sendall("\r\n".join(lines).encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        data = sock.recv(4096)
        if not data:
            break
        buf += data
    head, _, rest = buf.partition(b"\r\n\r\n")
    first, *fields = head.decode().split("\r\n")
    headers = {}
    for f in fields:
        k, _, v = f.partition(":")
        headers[k.strip().lower()] = v.strip()
    return sock, first, headers, key, rest


class WsClient(Client):
    """The same scripted client, one IRC message per WebSocket text frame."""

    def __init__(self, name, sock, rest=b""):
        super().__init__(None, name, sock=sock)
        self.raw = rest

    @classmethod
    def connect(cls, name, **kw):
        sock, status, headers, key, rest = ws_request(**kw)
        if " 101 " not in status:
            raise Fail(f"{name}: the handshake gave {status!r}")
        want = base64.b64encode(
            hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        if headers.get("sec-websocket-accept") != want:
            raise Fail(f"{name}: bad Sec-WebSocket-Accept {headers!r}")
        return cls(name, sock, rest)

    def _frame_bytes(self, op, payload):
        mask = os.urandom(4)
        n = len(payload)
        if n < 126:
            head = struct.pack("!BB", 0x80 | op, 0x80 | n)
        elif n < 65536:
            head = struct.pack("!BBH", 0x80 | op, 0x80 | 126, n)
        else:
            head = struct.pack("!BBQ", 0x80 | op, 0x80 | 127, n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return head + mask + masked

    def send(self, line):
        self.sock.sendall(self._frame_bytes(1, line.encode()))

    def send_raw_frame(self, op, payload):
        self.sock.sendall(self._frame_bytes(op, payload))

    def _parse(self):
        b = self.raw
        if len(b) < 2:
            return None
        op, n = b[0] & 0x0F, b[1] & 0x7F
        pos = 2
        if n == 126:
            if len(b) < 4:
                return None
            n, pos = struct.unpack("!H", b[2:4])[0], 4
        elif n == 127:
            if len(b) < 10:
                return None
            n, pos = struct.unpack("!Q", b[2:10])[0], 10
        if len(b) < pos + n:
            return None
        self.raw = b[pos + n:]
        return op, b[pos:pos + n]

    def next_frame(self, deadline):
        while True:
            f = self._parse()
            if f:
                return f
            left = deadline - time.time()
            if left <= 0:
                return None
            self.sock.settimeout(left)
            try:
                data = self.sock.recv(4096)
            except (socket.timeout, ssl.SSLError):
                return None
            if not data:
                raise Fail(f"{self.name}: connection closed")
            self.raw += data

    def _readline(self, deadline):
        while True:
            f = self.next_frame(deadline)
            if f is None:
                return None
            op, payload = f
            if op == 8:
                raise Fail(f"{self.name}: connection closed")
            if op == 9:
                self.send_raw_frame(10, payload)
                continue
            if op in (1, 2):
                text = payload.decode(errors="replace").rstrip("\r\n")
                self.seen.append(text)
                return text

    def close(self):
        try:
            self.send_raw_frame(8, struct.pack("!H", 1000))
        except OSError:
            pass
        super().close()
