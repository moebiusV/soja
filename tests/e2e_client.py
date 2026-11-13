"""A tiny scripted IRC client for tests/e2e.sh."""
import re
import socket
import time


class Fail(Exception):
    pass


class Client:
    def __init__(self, port, name):
        self.name = name
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
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
