"""The Milestone A scenario: soja between a client and a real ngircd."""
import os
import re
import signal
import shutil
import socket
import ssl
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from e2e_client import Client, Fail, WsClient, ws_request  # noqa: E402

SOJA = os.environ["SOJA_BIN"]
SOJACTL = os.environ["SOJACTL_BIN"]
CONF = os.environ["SOJA_CONF"]
DIR = os.environ["E2E_DIR"]
BOUNCER, SERVER = 6697, 6667

soja_proc = None


def log(msg):
    print(f"--- {msg}", flush=True)


def wait_port(port, timeout=15):
    end = time.time() + timeout
    while time.time() < end:
        try:
            socket.create_connection(("127.0.0.1", port), timeout=1).close()
            return
        except OSError:
            time.sleep(0.1)
    raise Fail(f"nothing listens on {port}")


def start_soja():
    global soja_proc
    out = open(os.path.join(DIR, "soja.log"), "ab")
    # The Web Push test pushes to a server on localhost, which soja refuses
    # unless this test hook is set (a push goes to external https only).
    soja_proc = subprocess.Popen([SOJA, "-config", CONF], stdout=out,
                                 stderr=out,
                                 env=dict(os.environ, SOJA_WEBPUSH_TEST="1"))
    wait_port(BOUNCER)


def stop_soja():
    soja_proc.send_signal(signal.SIGTERM)
    try:
        soja_proc.wait(timeout=20)
    except subprocess.TimeoutExpired:
        soja_proc.kill()
        raise Fail("soja did not stop on SIGTERM")


def bouncer(nick="alice", user="alice", password="secret"):
    c = Client(BOUNCER, f"bouncer:{user}")
    c.register(nick, user, password)
    return c


def bouncer_history(nick="alice", user="alice/test", password="secret",
                    caps="draft/chathistory batch server-time"):
    """A client that asked for some capabilities (chat history by default)."""
    c = Client(BOUNCER, f"history:{user}")
    c.send(f"CAP REQ :{caps}")
    c.expect(r"CAP \S+ ACK")
    c.send(f"PASS {password}")
    c.send(f"NICK {nick}")
    c.send(f"USER {user} 0 * :Test")
    c.send("CAP END")
    c.expect(r" 001 ")
    return c


def history_texts(c, query, timeout=10):
    """The PRIVMSG texts of the chathistory batch that answers a query."""
    c.send(query)
    c.expect(r"BATCH \+\S+ chathistory")
    texts = []
    while True:
        line = c.expect(r"PRIVMSG|BATCH -", timeout)
        if "BATCH -" in line:
            return texts
        texts.append(line.split(" :", 2)[-1] if " :" in line.split("PRIVMSG", 1)[1]
                     else line.rsplit(" ", 1)[-1])


def direct(nick):
    c = Client(SERVER, f"ngircd:{nick}")
    c.register(nick, nick)
    return c


def upstream_ports(known):
    """Our end of soja's connection to ngircd: local ports of established
    127.0.0.1 -> :6667 connections that are not the test's own."""
    out = []
    for line in open("/proc/net/tcp").read().splitlines()[1:]:
        f = line.split()
        lip, lport = f[1].split(":")
        rip, rport = f[2].split(":")
        if f[3] == "01" and int(rport, 16) == SERVER and lip == "0100007F":
            port = int(lport, 16)
            if port not in known:
                out.append(port)
    return out


def ask_identd(local, remote):
    s = socket.create_connection(("127.0.0.1", 1130), timeout=5)
    s.sendall(f"{local}, {remote}\r\n".encode())
    data = s.recv(512).decode()
    s.close()
    return data.strip()


def main():
    wait_port(SERVER)
    start_soja()

    # --- 3: register, add a network through BouncerServ, join a channel ---
    log("register and create a network")
    a = bouncer()
    a.send("PRIVMSG BouncerServ :network create -addr "
           "irc+insecure://127.0.0.1:6667 -name test")
    a.expect(r"BouncerServ.* NOTICE alice :created network|PRIVMSG alice :created network")
    a.close()

    # bob is in #t first (so he is its operator) and watches.
    b = direct("bob")
    b.send("JOIN #t")
    b.expect(r" 366 ")

    log("join through the bouncer")
    a = bouncer(user="alice/test")
    a.send("JOIN #t")
    a.expect(r":alice!\S+ JOIN :?#t")
    a.expect(r" 366 ")
    b.expect(r":alice!\S+ JOIN :?#t")

    log("identd answers for the upstream connection")
    mine = {b.sock.getsockname()[1]}
    ports = upstream_ports(mine)
    if len(ports) != 1:
        raise Fail(f"expected one upstream connection, found {ports}")
    answer = ask_identd(ports[0], SERVER)
    if not re.fullmatch(rf"{ports[0]}, {SERVER} : USERID : UNKNOWN : [0-9a-f]{{32}}",
                        answer):
        raise Fail(f"unexpected identd answer: {answer!r}")
    if "NO-USER" not in ask_identd(ports[0] + 1, SERVER):
        raise Fail("identd answered for an unknown connection")

    log("sojactl and the admin socket")
    sock = os.path.join(DIR, "admin.sock")
    mode = os.stat(sock).st_mode & 0o777
    if mode != 0o600:
        raise Fail(f"admin socket has mode {mode:o}, wanted 600")

    def ctl(*words):
        return subprocess.run([SOJACTL, "-config", CONF, *words],
                              capture_output=True, text=True, timeout=20)

    r = ctl("user", "status")
    if r.returncode != 0 or "alice: 1 networks" not in r.stdout:
        raise Fail(f"user status: {r.returncode} {r.stdout!r} {r.stderr!r}")
    r = ctl("user", "create", "-username", "carol", "-password", "pw")
    if r.returncode != 0 or 'created user "carol"' not in r.stdout:
        raise Fail(f"user create: {r.stdout!r} {r.stderr!r}")
    r = ctl("user", "status")
    if "carol: 0 networks" not in r.stdout:
        raise Fail(f"carol is not listed: {r.stdout!r}")
    r = ctl("user", "run", "alice", "network", "status")
    if r.returncode != 0 or "test" not in r.stdout or "connected" not in r.stdout:
        raise Fail(f"user run: {r.stdout!r} {r.stderr!r}")
    r = ctl("server", "status")
    if r.returncode != 0 or "users" not in r.stdout:
        raise Fail(f"server status: {r.stdout!r} {r.stderr!r}")
    r = ctl("user", "create", "-username", "carol", "-password", "pw")
    if r.returncode == 0 or "could not create user" not in r.stderr:
        raise Fail(f"a duplicate user must fail: {r.stdout!r} {r.stderr!r}")
    r = ctl("frobnicate")
    if r.returncode == 0 or "not found" not in r.stderr:
        raise Fail(f"an unknown command must fail: {r.stdout!r} {r.stderr!r}")
    # a word with a space survives the quoting
    r = ctl("user", "run", "alice", "network", "create", "-addr",
            "irc+insecure://127.0.0.1:1", "-name", "two words", "-enabled", "false")
    if r.returncode != 0 or 'created network "two words"' not in r.stdout:
        raise Fail(f"quoting: {r.stdout!r} {r.stderr!r}")

    log("a client over the unix:// socket")
    path = os.path.join(DIR, "irc.sock")
    mode = os.stat(path).st_mode & 0o777
    if mode != 0o775:
        raise Fail(f"unix socket has mode {mode:o}, wanted 775")
    u = Client(None, "unix:alice/test", path=path)
    u.register("alice", "alice/test", "secret")
    u.send("PRIVMSG BouncerServ :network status")
    u.expect(r"test .*connected")
    u.close()

    log("WebSocket listeners (ws, wss, ws+unix, http)")
    for how, kw in (("ws+insecure", dict(port=8081)),
                    ("wss", dict(port=8443, tls=True)),
                    ("ws+unix", dict(unix=os.path.join(DIR, "ws.sock"))),
                    ("http /socket", dict(port=8082, path="/socket"))) \
            * int(os.environ.get("WS_REPEAT", "1")):
        w = WsClient.connect(f"{how}:alice", **kw)
        w.register("alice", "alice/test", "secret")
        w.send("PING :wsping")
        w.expect(r"PONG .*wsping")
        w.send("PRIVMSG BouncerServ :network status")
        w.expect(r"test .*connected")
        # a long message crosses the 16-bit frame length
        w.send("PRIVMSG alice :" + "x" * 400)
        w.expect(r"PRIVMSG alice :?x{400}")
        w.send_raw_frame(9, b"ping-data")        # a ping gets a pong
        end = time.time() + 5
        while True:
            f = w.next_frame(end)
            if f is None:
                raise Fail(f"{how}: no pong")
            if f[0] == 10 and f[1] == b"ping-data":
                break
        w.close()
    w = WsClient.connect("ws:whois", port=8081)
    w.register("alice", "alice", "secret")
    w.send("WHOIS alice")
    w.expect(r" 311 alice alice alice 127\.0\.0\.1 ")
    w.close()
    # the subprotocol is chosen when offered
    s, status, h, _, _ = ws_request(
        port=8081, extra=["Sec-WebSocket-Protocol: foo, text.ircv3.net"])
    s.close()
    if " 101 " not in status or h.get("sec-websocket-protocol") != "text.ircv3.net":
        raise Fail(f"subprotocol: {status!r} {h!r}")
    # origins: the request's host and http-origin patterns pass, others do not
    for origin, want in (("http://127.0.0.1:8081", "101"),
                         ("https://app.allowed.example", "101"),
                         ("https://evil.example", "403"),
                         ("null", "403")):
        s, status, _, _, _ = ws_request(port=8081,
                                        extra=[f"Origin: {origin}"])
        s.close()
        if f" {want} " not in status:
            raise Fail(f"origin {origin!r}: {status!r}, wanted {want}")
    # not a WebSocket request, wrong paths and methods
    for kw, want in ((dict(port=8081, extra=["X-Dummy: 1"], method="POST"), "405"),
                     (dict(port=8082, path="/"), "404"),
                     (dict(port=8082, path="/uploads/x"), "404")):
        s, status, _, _, _ = ws_request(**kw)
        s.close()
        if f" {want} " not in status:
            raise Fail(f"{kw}: {status!r}, wanted {want}")
    # behind a trusted proxy (accept-proxy-ip localhost) the address comes
    # from Forwarded, and an untrusted peer cannot spoof it (checked by the
    # unit tests; here localhost is the trusted one)
    for fwd, want in (("for=192.0.2.7", r"192\.0\.2\.7"),
                      ('for="192.0.2.8:4000"', r"192\.0\.2\.8")):
        w = WsClient.connect("ws:fwd", port=8081,
                             extra=[f"Forwarded: {fwd}"])
        w.register("alice", "alice", "secret")
        w.send("WHOIS alice")
        w.expect(rf" 311 alice alice alice {want} ")
        w.close()
    w = WsClient.connect("ws:xff", port=8081,
                         extra=["X-Forwarded-For: 192.0.2.9"])
    w.register("alice", "alice", "secret")
    w.send("WHOIS alice")
    w.expect(r" 311 alice alice alice 192\.0\.2\.9 ")
    w.close()
    # a protocol violation (an unmasked frame) is refused with a close frame
    s, status, _, _, _ = ws_request(port=8081)
    s.sendall(b"\x81\x04PING")                 # unmasked
    data = b""
    try:
        while len(data) < 4:
            chunk = s.recv(64)
            if not chunk:
                break
            data += chunk
    except OSError:
        pass
    s.close()
    if not data or data[0] & 0x0F != 8:
        raise Fail(f"an unmasked frame was not answered with a close: {data!r}")

    log("no descriptors leak from closed WebSocket connections")

    def open_fds():
        return len(os.listdir(f"/proc/{soja_proc.pid}/fd"))

    before = open_fds()
    for i in range(30):
        w = WsClient.connect(f"ws:leak{i}", port=8081)
        w.register("alice", "alice", "secret")
        w.close()
    # connections that end without a close frame, and a refused handshake
    for i in range(10):
        s, _, _, _, _ = ws_request(port=8081)
        s.close()
        s, _, _, _, _ = ws_request(port=8081, extra=["Origin: https://evil.example"])
        s.close()
    time.sleep(2)
    after = open_fds()
    if after > before + 4:
        raise Fail(f"descriptors leaked: {before} open before, {after} after")

    log("connections that reset do not stop the listeners or leak descriptors")
    import struct
    import threading

    def hammer(port, n):
        for _ in range(n):
            try:
                c = socket.create_connection(("127.0.0.1", port), timeout=2)
                c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                             struct.pack("ii", 1, 0))   # close sends RST
                c.close()
            except OSError:
                pass
    # more connections than the default descriptor limit (1024)
    before = open_fds()
    ts = [threading.Thread(target=hammer, args=(p, 100))
          for p in (BOUNCER, 8081, 8082) for _ in range(6)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    time.sleep(2)
    if open_fds() > before + 20:
        raise Fail(f"descriptors leaked by resets: {before} -> {open_fds()}")
    wait_port(BOUNCER)
    bouncer().close()
    w = WsClient.connect("ws:after-storm", port=8081)
    w.register("alice", "alice", "secret")
    w.close()

    log("the PROXY protocol, from a trusted peer")
    p = Client(BOUNCER, "proxied")
    p.send("PROXY TCP4 10.9.8.7 127.0.0.1 51234 6697")
    p.register("alice", "alice", "secret")
    p.send("WHOIS alice")
    p.expect(r" 311 alice alice alice 10\.9\.8\.7 ")
    p.close()
    p = Client(BOUNCER, "proxied6")
    p.send("PROXY TCP6 2001:db8::5 ::1 51234 6697")
    p.register("alice", "alice", "secret")
    p.send("WHOIS alice")
    p.expect(r" 311 alice alice alice 2001:db8::5 ")
    p.close()
    # a client that sends no header is served as before (address 127.0.0.1)
    p = Client(BOUNCER, "unproxied")
    p.register("alice", "alice", "secret")
    p.send("WHOIS alice")
    p.expect(r" 311 alice alice alice 127\.0\.0\.1 ")
    p.close()
    # a malformed header drops the connection
    p = Client(BOUNCER, "badheader")
    p.send("PROXY TCP4 not-an-address 127.0.0.1 1 2")
    try:
        p.expect(r"never", timeout=5)
        raise Fail("a malformed PROXY header was accepted")
    except Fail as e:
        if "connection closed" not in str(e):
            raise
    p.close()
    # identd matches the address the header names
    s1 = socket.create_connection(("127.0.0.1", 1130), timeout=5)
    s1.sendall(f"PROXY TCP4 127.0.0.1 127.0.0.1 1 113\r\n{ports[0]}, {SERVER}\r\n".encode())
    r1 = s1.recv(512).decode()
    s1.close()
    if "USERID" not in r1:
        raise Fail(f"identd ignored the PROXY source: {r1!r}")
    s2 = socket.create_connection(("127.0.0.1", 1130), timeout=5)
    s2.sendall(f"PROXY TCP4 10.9.8.7 127.0.0.1 1 113\r\n{ports[0]}, {SERVER}\r\n".encode())
    r2 = s2.recv(512).decode()
    s2.close()
    if "NO-USER" not in r2:
        raise Fail(f"identd matched the wrong host: {r2!r}")

    log("certificate reload on SIGHUP")

    def served_cert():
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with socket.create_connection(("127.0.0.1", 6698), timeout=5) as raw:
            with ctx.wrap_socket(raw) as tls:
                return tls.getpeercert(binary_form=True)

    def reload():
        soja_proc.send_signal(signal.SIGHUP)
        time.sleep(1.0)

    cert_a = served_cert()
    shutil.copy(os.path.join(DIR, "b.crt"), os.path.join(DIR, "tls.crt"))
    shutil.copy(os.path.join(DIR, "b.key"), os.path.join(DIR, "tls.key"))
    if served_cert() != cert_a:
        raise Fail("the new certificate was used before any SIGHUP")
    reload()
    cert_b = served_cert()
    if cert_b == cert_a:
        raise Fail("SIGHUP did not make soja serve the new certificate")
    # a broken replacement is refused and the old one stays
    with open(os.path.join(DIR, "tls.crt"), "w") as f:
        f.write("not a certificate\n")
    reload()
    if served_cert() != cert_b:
        raise Fail("a broken certificate replaced the working one")
    # an ircs client still works (and a session survives): register over TLS
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    raw = socket.create_connection(("127.0.0.1", 6698), timeout=5)
    tc = Client(None, "tls", sock=ctx.wrap_socket(raw))
    tc.register("alice", "alice", "secret")
    tc.close()
    # put a good pair back, for the restart below
    shutil.copy(os.path.join(DIR, "a.crt"), os.path.join(DIR, "tls.crt"))
    shutil.copy(os.path.join(DIR, "a.key"), os.path.join(DIR, "tls.key"))

    log("messages both ways")
    b.send("PRIVMSG #t :hello from bob")
    a.expect(r":bob!\S+ PRIVMSG #t :hello from bob")
    a.send("PRIVMSG #t :hi bob")
    b.expect(r":alice!\S+ PRIVMSG #t :hi bob")

    # --- 5: a kick is not undone ---
    log("kick: no automatic rejoin")
    b.send("KICK #t alice :bye")
    a.expect(r" KICK #t alice")
    b.expect(r" KICK #t alice")
    time.sleep(6)
    b.send("NAMES #t")
    names = b.expect(r" 353 ")
    if "alice" in names:
        raise Fail(f"soja rejoined #t after the kick: {names}")
    b.expect(r" 366 ")

    # --- 6: the bouncer property: replay without a new upstream JOIN ---
    log("replay on reconnect")
    a.send("JOIN #u")
    a.expect(r":alice!\S+ JOIN :?#u")
    b.send("JOIN #u")
    b.expect(r" 366 ")
    b.drain(0.5)
    a.close()
    time.sleep(0.5)
    b.send("PRIVMSG #u :while you were away")
    time.sleep(0.5)
    a = bouncer(user="alice/test")
    a.expect(r":alice!\S+ JOIN :?#u")
    a.expect(r" 366 .*#u|#u :End of /NAMES")
    a.expect(r"while you were away")
    extra = b.drain(1.5)
    if any((" JOIN" in l or " QUIT" in l or " PART" in l)
           and "alice" in l for l in extra):
        raise Fail("bob saw alice leave or join #u again: " + repr(extra))

    # --- chat history (database store), also across a restart ---
    log("chat history")
    b.send("PRIVMSG #u :history one")
    b.send("PRIVMSG #u :history two")
    time.sleep(1.0)
    h = bouncer_history()
    got = history_texts(h, "CHATHISTORY LATEST #u * 50")
    for want in ("while you were away", "history one", "history two"):
        if want not in got:
            raise Fail(f"history lacks {want!r}: {got}")
    if got.index("history one") > got.index("history two"):
        raise Fail(f"history is not oldest first: {got}")
    one = history_texts(h, "CHATHISTORY LATEST #u * 1")
    if one != ["history two"]:
        raise Fail(f"LATEST * 1 should be the newest message: {one}")
    h.send("CHATHISTORY TARGETS timestamp=2000-01-01T00:00:00.000Z "
           "timestamp=2100-01-01T00:00:00.000Z 10")
    h.expect(r"BATCH \+\S+ draft/chathistory-targets")
    h.expect(r"CHATHISTORY TARGETS #u ")
    h.send("SEARCH in=#u;text=HISTORY")        # any case
    h.expect(r"BATCH \+\S+ soju.im/search")
    h.close()

    if os.environ.get("E2E_STORE") == "fs":
        log("the log files (ZNC format) on disk")
        net_dir = os.path.join(DIR, "logs", "alice", "test", "#u")
        files = sorted(os.listdir(net_dir))
        if not files or not all(re.fullmatch(r"\d{4}-\d\d-\d\d\.log", f)
                                for f in files):
            raise Fail(f"unexpected log files: {files}")
        text = "".join(open(os.path.join(net_dir, f)).read() for f in files)
        if not re.search(r"^\[\d\d:\d\d:\d\d\] <bob> history one$", text, re.M):
            raise Fail(f"no ZNC-format line in the log: {text!r}")
        if not re.search(r"^\[\d\d:\d\d:\d\d\] \*\*\* Joins: ", text, re.M):
            raise Fail(f"no join event in the log: {text!r}")
        d_mode = os.stat(net_dir).st_mode & 0o777
        f_mode = os.stat(os.path.join(net_dir, files[0])).st_mode & 0o777
        if d_mode != 0o750 or f_mode != 0o640:
            raise Fail(f"modes: dir {d_mode:o} (want 750), file {f_mode:o} (want 640)")

    # --- read markers: stored, replayed to a new client, kept across restarts
    log("read markers")
    marker = "timestamp=2026-01-02T03:04:05.000Z"
    r = bouncer_history(caps="draft/read-marker")
    r.send("MARKREAD #u")
    r.expect(r"MARKREAD #u \*")
    r.send(f"MARKREAD #u {marker}")
    r.expect(rf"MARKREAD #u {marker}")
    r.send("MARKREAD #u timestamp=2025-01-01T00:00:00.000Z")   # older: ignored
    r.expect(rf"MARKREAD #u {marker}")
    r.close()
    r = bouncer_history(caps="draft/read-marker")
    r.expect(rf"MARKREAD #u {marker}")      # replayed with the channel
    r.close()

    # --- 7: restart: reconnect and rejoin the saved channels once ---
    webpush_section(b)
    log("certfp generate: SASL EXTERNAL with the generated certificate")
    import hashlib
    import sqlite3
    import threading

    # an ircs "upstream" that asks for a client certificate and speaks just
    # enough IRC for SASL EXTERNAL
    server_cert = os.path.join(DIR, "tls.crt")
    server_key = os.path.join(DIR, "tls.key")
    with open(server_cert) as f:
        server_der = ssl.PEM_cert_to_DER_cert(f.read())
    server_fp = hashlib.sha256(server_der).hexdigest()
    seen = {"peer": None, "lines": [], "done": threading.Event()}
    ctx_holder = {}

    def fake_ircs(listener):
        conn, _ = listener.accept()
        conn.settimeout(10)
        try:
            tconn = ctx_holder["ctx"].wrap_socket(conn, server_side=True)
        except (ssl.SSLError, OSError) as e:
            seen["error"] = str(e)
            seen["done"].set()
            return
        seen["peer"] = tconn.getpeercert(binary_form=True)
        buf = b""
        nick = "alice"
        try:
            while not seen["done"].is_set():
                data = tconn.recv(4096)
                if not data:
                    break
                buf += data
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    text = line.decode(errors="replace").strip()
                    seen["lines"].append(text)
                    if text.startswith("NICK "):
                        nick = text.split()[1]
                    if text.startswith("CAP LS"):
                        tconn.sendall(b":irc CAP * LS :sasl\r\n")
                    elif text.startswith("CAP REQ"):
                        tconn.sendall(b":irc CAP * ACK :sasl\r\n")
                    elif text == "AUTHENTICATE EXTERNAL":
                        tconn.sendall(b"AUTHENTICATE +\r\n")
                    elif text == "AUTHENTICATE +":
                        tconn.sendall(
                            f":irc 903 {nick} :SASL authentication successful\r\n".encode())
                    elif text == "CAP END":
                        tconn.sendall(
                            f":irc 001 {nick} :Welcome\r\n".encode())
                        seen["done"].set()
        except (ssl.SSLError, OSError):
            pass
        finally:
            seen["done"].set()
            tconn.close()

    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 7070))
    listener.listen(1)
    listener.settimeout(30)

    c = bouncer()
    c.send("PRIVMSG BouncerServ :network create -addr ircs://127.0.0.1:7070 "
           f"-name tlsnet -certfp {server_fp} -enabled false")
    c.expect(r'created network "tlsnet"')
    c.send("PRIVMSG BouncerServ :certfp generate -network tlsnet "
           "-key-type ed25519")
    c.expect(r"certificate generated")
    c.expect(r"SHA-256 fingerprint: [0-9a-f]{64}")
    c.send("PRIVMSG BouncerServ :sasl status -network tlsnet")
    c.expect(r"SASL EXTERNAL \(CertFP\) enabled")

    # the certificate is stored as DER, as soju stores it
    db = sqlite3.connect(os.path.join(DIR, "soja.db"))
    cert_der, key_der = db.execute(
        "SELECT sasl_external_cert, sasl_external_key FROM Network "
        "WHERE name = 'tlsnet'").fetchone()
    db.close()
    if not cert_der or cert_der[0] != 0x30 or not key_der or key_der[0] != 0x30:
        raise Fail("the certificate or key is not stored as DER")
    cert_pem = ssl.DER_cert_to_PEM_cert(bytes(cert_der))
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(server_cert, server_key)
    ctx.verify_mode = ssl.CERT_OPTIONAL
    # the certificate is a leaf (its issuer is not kept): trust it as it is
    ctx.verify_flags |= ssl.VERIFY_X509_PARTIAL_CHAIN
    ctx.load_verify_locations(cadata=cert_pem)
    ctx_holder["ctx"] = ctx
    t = threading.Thread(target=fake_ircs, args=(listener,), daemon=True)
    t.start()

    c.send("PRIVMSG BouncerServ :network update tlsnet -enabled true")
    c.expect(r'updated network "tlsnet"')
    if not seen["done"].wait(30):
        raise Fail(f"the fake server did not finish: {seen}")
    if seen.get("error") or seen["peer"] != bytes(cert_der):
        raise Fail(f"the upstream did not see the generated certificate: "
                   f"{seen.get('error')!r} {seen['lines']}")
    if "AUTHENTICATE EXTERNAL" not in seen["lines"]:
        raise Fail(f"no SASL EXTERNAL: {seen['lines']}")
    listener.close()
    # key types, and a missing network
    for kt in ("ecdsa", "rsa"):
        c.send(f"PRIVMSG BouncerServ :certfp generate -network tlsnet "
               f"-key-type {kt}" + (" -bits 2048" if kt == "rsa" else ""))
        c.expect(r"certificate generated", timeout=60)
    c.send("PRIVMSG BouncerServ :certfp generate -network tlsnet -key-type dsa")
    c.expect(r"error: unknown key type")
    c.send("PRIVMSG BouncerServ :network delete tlsnet")
    c.expect(r'deleted network "tlsnet"')
    c.close()

    log("file upload")
    import base64
    import http.client

    c = bouncer()
    c.drain(1.5)
    filehost = [l for l in c.seen if "soju.im/FILEHOST=" in l]
    c.close()
    if not filehost or "soju.im/FILEHOST=https://soja.example.net/uploads" \
            not in filehost[0]:
        raise Fail(f"ISUPPORT FILEHOST missing or wrong: {filehost}")

    def http_call(method, path, body=None, headers=None, user="alice",
                  password="secret"):
        conn = http.client.HTTPConnection("127.0.0.1", 8082, timeout=10)
        h = dict(headers or {})
        if user is not None:
            h["Authorization"] = "Basic " + base64.b64encode(
                f"{user}:{password}".encode()).decode()
        conn.request(method, path, body=body, headers=h)
        r = conn.getresponse()
        data = r.read()
        out = (r.status, dict((k.lower(), v) for k, v in r.getheaders()), data)
        conn.close()
        return out

    payload = os.urandom(3_000_000) + b"end"
    st, hd, _ = http_call("POST", "/uploads", payload, {
        "Content-Type": "application/octet-stream",
        "Content-Disposition": 'attachment; filename="my photo.png"'})
    if st != 201 or not hd["location"].startswith("/uploads/alice/") \
            or not hd["location"].endswith("-my%20photo.png"):
        raise Fail(f"upload: {st} {hd}")
    loc = hd["location"]
    st, hd, data = http_call("GET", loc, user=None)
    if st != 200 or data != payload:
        raise Fail(f"download: {st} {len(data)} bytes, wanted {len(payload)}")
    if hd["content-type"] != "image/png" \
            or not hd["content-disposition"].startswith("inline") \
            or 'filename="my photo.png"' not in hd["content-disposition"] \
            or hd["content-length"] != str(len(payload)) \
            or hd["accept-ranges"] != "bytes":
        raise Fail(f"download headers: {hd}")
    if "sandbox" not in hd["content-security-policy"]:
        raise Fail(f"no CSP: {hd}")
    st, hd, data = http_call("GET", loc, headers={"Range": "bytes=10-19"},
                             user=None)
    if st != 206 or data != payload[10:20] \
            or hd["content-range"] != f"bytes 10-19/{len(payload)}":
        raise Fail(f"range: {st} {hd} {data!r}")
    st, hd, data = http_call("HEAD", loc, user=None)
    if st != 200 or data != b"" or hd["content-length"] != str(len(payload)):
        raise Fail(f"head: {st} {hd}")
    st, _, _ = http_call("GET", loc, headers={"Range": "bytes=999999999-"},
                         user=None)
    if st != 416:
        raise Fail(f"unsatisfiable range: {st}")
    # who may upload
    if http_call("POST", "/uploads", b"x", user=None)[0] != 401:
        raise Fail("upload without credentials")
    if http_call("POST", "/uploads", b"x", password="nope")[0] != 403:
        raise Fail("upload with a wrong password")
    if http_call("GET", "/uploads/alice/../../etc/passwd", user=None)[0] != 404:
        raise Fail("path traversal")
    # CORS: the origin of the request's host, a foreign one, a pattern
    st, hd, _ = http_call("OPTIONS", "/uploads", user=None,
                          headers={"Origin": "http://127.0.0.1:8082"})
    if st != 204 or hd.get("access-control-allow-origin") \
            != "http://127.0.0.1:8082" or hd.get("vary") != "Origin":
        raise Fail(f"CORS: {st} {hd}")
    if http_call("OPTIONS", "/uploads", user=None,
                 headers={"Origin": "https://evil.example"})[0] != 403:
        raise Fail("CORS for a foreign origin")
    # on disk: the user's directory is private
    base = os.path.join(DIR, "uploads", "alice")
    files = os.listdir(base)
    if len(files) != 1 or not files[0].endswith("-my photo.png"):
        raise Fail(f"files on disk: {files}")
    if os.stat(base).st_mode & 0o777 != 0o700 \
            or os.stat(os.path.join(base, files[0])).st_mode & 0o777 != 0o600:
        raise Fail("upload modes")
    if os.path.getsize(os.path.join(base, files[0])) != len(payload):
        raise Fail("size on disk")

    log("Prometheus metrics")
    import urllib.request

    def scrape():
        with urllib.request.urlopen("http://localhost:9100/metrics",
                                    timeout=5) as r:
            if not r.headers["Content-Type"].startswith("text/plain"):
                raise Fail(f"metrics content type {r.headers['Content-Type']!r}")
            out = {}
            for line in r.read().decode().splitlines():
                if line and not line.startswith("#"):
                    name, value = line.split(" ")
                    out[name] = int(value)
            return out

    m1 = scrape()
    for name in ("soju_users_active", "soju_downstreams_active",
                 "soju_upstreams_active", "soju_downstream_in_messages_total",
                 "soju_downstream_out_messages_total",
                 "soju_upstream_in_messages_total",
                 "soju_upstream_out_messages_total",
                 "soju_upstream_connect_errors_total",
                 "soju_worker_panics_total"):
        if name not in m1:
            raise Fail(f"metric {name} missing: {sorted(m1)}")
    if m1["soju_users_active"] < 1 or m1["soju_upstreams_active"] < 1:
        raise Fail(f"gauges look wrong: {m1}")
    if m1["soju_downstream_in_messages_total"] < 10 \
            or m1["soju_upstream_in_messages_total"] < 10:
        raise Fail(f"counters look wrong: {m1}")
    # traffic moves the counters, and a closed client moves the gauge back
    c = bouncer()
    during = scrape()
    c.send("PING :metrics")
    c.expect(r"PONG")
    c.close()
    time.sleep(1)
    m2 = scrape()
    if during["soju_downstreams_active"] <= m1["soju_downstreams_active"] - 1 \
            or m2["soju_downstream_in_messages_total"] \
            <= m1["soju_downstream_in_messages_total"] \
            or m2["soju_downstream_out_messages_total"] \
            <= m1["soju_downstream_out_messages_total"]:
        raise Fail(f"counters did not move: {m1} -> {during} -> {m2}")
    if m2["soju_downstreams_active"] >= during["soju_downstreams_active"]:
        raise Fail(f"gauge did not drop: {during} -> {m2}")

    log("restart soja")
    a.close()
    stop_soja()
    b.drain(1.0)
    start_soja()
    joined = b.expect(r":alice!\S+ JOIN :?#u", timeout=30)
    again = b.drain(3)
    if any(":alice!" in l and " JOIN" in l for l in again):
        raise Fail("soja joined #u twice after the restart")
    # the history is still there after the restart: it is in the database
    h = bouncer_history()
    got = history_texts(h, "CHATHISTORY LATEST #u * 50")
    if "history one" not in got or "history two" not in got:
        raise Fail(f"history was lost across the restart: {got}")
    h.close()
    r = bouncer_history(caps="draft/read-marker")
    r.expect(rf"MARKREAD #u {marker}")      # the marker is in the database too
    r.close()
    log("all good: " + joined)


def pam_section():
    """auth pam: PAM's `soju` service, with a password the module reads."""
    check = os.path.join(DIR, "pamcheck.sh")
    with open(check, "w") as f:
        f.write('#!/bin/sh\nread p\n[ "$PAM_USER" = pamuser ] && '
                '[ "$p" = pamsecret ]\n')
    os.chmod(check, 0o755)
    try:
        os.makedirs("/etc/pam.d", exist_ok=True)
        with open("/etc/pam.d/soju", "w") as f:
            f.write("auth requisite pam_exec.so expose_authtok quiet "
                    f"{check}\naccount required pam_permit.so\n")
    except OSError:
        log("auth pam: skipped (cannot write /etc/pam.d)")
        return
    conf = os.path.join(DIR, "pam.conf")
    with open(conf, "w") as f:
        f.write("listen irc+insecure://127.0.0.1:6700\n"
                "hostname soja.example.net\n"
                f"db sqlite3 {DIR}/pam.db\n"
                "enable-user-on-auth true\nauth pam\n")
    out = open(os.path.join(DIR, "pam.log"), "ab")
    p = subprocess.Popen([SOJA, "-config", conf], stdout=out, stderr=out)
    try:
        wait_port(6700)
        c = Client(6700, "pam:ok")
        c.register("pamuser", "pamuser", "pamsecret")
        c.close()
        for user, pw in (("pamuser", "wrong"), ("other", "pamsecret")):
            c = Client(6700, "pam:bad")
            c.send(f"PASS {pw}")
            c.send(f"NICK {user}")
            c.send(f"USER {user} 0 * :x")
            c.expect(r" 464 |ERROR|FAIL")
            c.close()
    finally:
        p.kill()
    log("auth pam: PAM soju service")


def webpush_section(bob):
    """soju.im/webpush: registration, the encrypted push, the VAPID header."""
    import base64
    import http.server
    import threading
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import \
        encode_dss_signature
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF, HKDFExpand

    def b64(b):
        return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

    def unb64(t):
        return base64.urlsafe_b64decode(t + "=" * (-len(t) % 4))

    got = []

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(n)
            got.append((self.path, dict(self.headers), body))
            self.send_response(404 if self.path == "/gone" else 201)
            self.send_header("Content-Length", "0")
            self.end_headers()

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 9202), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    ua_priv = ec.generate_private_key(ec.SECP256R1())
    ua_pub = ua_priv.public_key().public_bytes(
        serialization.Encoding.X962,
        serialization.PublicFormat.UncompressedPoint)
    auth = os.urandom(16)

    def decrypt(body):
        salt, rs, idlen = body[:16], int.from_bytes(body[16:20], "big"), body[20]
        as_pub = body[21:21 + idlen]
        if rs != 2048 or idlen != 65:
            raise Fail(f"push record size {rs}, key length {idlen}")
        shared = ua_priv.exchange(
            ec.ECDH(), ec.EllipticCurvePublicKey.from_encoded_point(
                ec.SECP256R1(), as_pub))
        ikm = HKDFExpand(hashes.SHA256(), 32,
                         b"WebPush: info\0" + ua_pub + as_pub).derive(
            _prk(auth, shared))
        prk = _prk(salt, ikm)
        cek = HKDFExpand(hashes.SHA256(), 16,
                         b"Content-Encoding: aes128gcm\0").derive(prk)
        nonce = HKDFExpand(hashes.SHA256(), 12,
                           b"Content-Encoding: nonce\0").derive(prk)
        plain = AESGCM(cek).decrypt(nonce, body[21 + idlen:], None)
        return plain.rstrip(b"\0")[:-1].decode()

    def _prk(salt, ikm):
        import hmac
        import hashlib
        return hmac.new(salt, ikm, hashlib.sha256).digest()

    def wait_push(count, timeout=10):
        end = time.time() + timeout
        while time.time() < end:
            if len(got) >= count:
                return got[count - 1]
            time.sleep(0.1)
        raise Fail(f"no Web Push request #{count}; got {len(got)}")

    try:
        c = bouncer_history(caps="soju.im/webpush")
        c.drain(1.0)
        vapid = None
        for line in c.seen:
            m = re.search(r" VAPID=(\S+)", line)
            if m:
                vapid = m.group(1)
        if not vapid:
            raise Fail("no VAPID in ISUPPORT: " + repr(c.seen))
        ep = "http://127.0.0.1:9202/push/1"
        keys = f"auth={b64(auth)};p256dh={b64(ua_pub)}"
        c.send(f"WEBPUSH REGISTER {ep} :{keys}")
        c.expect(rf"WEBPUSH REGISTER {re.escape(ep)}")
        path, hdr, body = wait_push(1)
        if path != "/push/1" or hdr.get("Content-Encoding") != "aes128gcm":
            raise Fail(f"bad push request: {path} {hdr}")
        if hdr.get("Urgency") != "normal" or hdr.get("TTL") != "604800":
            raise Fail(f"bad push headers: {hdr}")
        text = decrypt(body)
        if text != "NOTE WEBPUSH REGISTERED :Push notifications enabled":
            raise Fail(f"bad test push: {text!r}")
        # the VAPID header: a JWT signed by the key of ISUPPORT
        m = re.fullmatch(r"vapid t=(\S+)\.(\S+)\.(\S+), k=(\S+)",
                         hdr["Authorization"])
        if not m or m.group(4) != vapid:
            raise Fail(f"bad VAPID header: {hdr['Authorization']}")
        sig = unb64(m.group(3))
        pub = ec.EllipticCurvePublicKey.from_encoded_point(
            ec.SECP256R1(), unb64(vapid))
        pub.verify(encode_dss_signature(int.from_bytes(sig[:32], "big"),
                                        int.from_bytes(sig[32:], "big")),
                   (m.group(1) + "." + m.group(2)).encode(),
                   ec.ECDSA(hashes.SHA256()))
        claims = unb64(m.group(2)).decode()
        if '"aud":"http://127.0.0.1:9202"' not in claims or \
                '"sub":"https://soju.im"' not in claims:
            raise Fail(f"bad JWT claims: {claims}")

        # a highlight is pushed, with a high urgency
        bob.send("PRIVMSG #u :alice: web push please")
        path, hdr, body = wait_push(2)
        text = decrypt(body)
        if "PRIVMSG #u" not in text or "web push please" not in text \
                or hdr.get("Urgency") != "high":
            raise Fail(f"bad highlight push: {text!r} {hdr}")

        # an endpoint that is gone is refused; a repeated register is quiet
        c.send(f"WEBPUSH REGISTER http://127.0.0.1:9202/gone :{keys}")
        c.expect(r"FAIL WEBPUSH INVALID_PARAMS REGISTER :Invalid endpoint")
        n = len(got)
        c.send(f"WEBPUSH REGISTER {ep} :{keys}")
        c.expect(rf"WEBPUSH REGISTER {re.escape(ep)}")
        c.send("WEBPUSH REGISTER x")
        c.expect(r" 461 \S+ WEBPUSH :Not enough parameters")
        c.send("WEBPUSH BOGUS")
        c.expect(r"FAIL WEBPUSH INVALID_PARAMS BOGUS :Unknown command")
        if len(got) != n:
            raise Fail("a repeated registration sent a new test push")

        # after UNREGISTER nothing is pushed
        c.send(f"WEBPUSH UNREGISTER {ep}")
        c.expect(rf"WEBPUSH UNREGISTER {re.escape(ep)}")
        n = len(got)
        bob.send("PRIVMSG #u :alice: and again")
        time.sleep(2)
        if len(got) != n:
            raise Fail("pushed after UNREGISTER")
        c.close()
    finally:
        srv.shutdown()
    log("web push: registration, encrypted push and VAPID verified")


def listen_schemes_section():
    """irc://, ws://, http:// (localhost only), and the insecure Prometheus."""
    sock = socket.create_connection(("localhost", 6701), timeout=5)
    c = Client(None, "irc://localhost", sock=sock)
    c.register("alice", "alice", "secret")
    c.close()
    w = WsClient.connect("ws://localhost", port=8083, address="localhost")
    w.register("alice", "alice", "secret")
    w.close()
    w = WsClient.connect("http://localhost", port=8084, path="/socket",
                         address="localhost")
    w.register("alice", "alice", "secret")
    w.close()
    import urllib.request
    with urllib.request.urlopen("http://127.0.0.1:9101/metrics",
                                timeout=5) as r:
        if b"soju_users_active" not in r.read():
            raise Fail("no metrics on http+insecure+prometheus://")
    # a plain-text listener on another host than localhost is refused
    for uri, want in (("irc://0.0.0.0:6799", "Plain-text IRC"),
                      ("ws://0.0.0.0:6799", "Plain-text WebSocket"),
                      ("http://0.0.0.0:6799", "Plain-text HTTP"),
                      ("http+prometheus://0.0.0.0:6799", "Prometheus")):
        conf = os.path.join(DIR, "listen.conf")
        with open(conf, "w") as f:
            f.write(f"listen {uri}\ndb sqlite3 {DIR}/listen.db\n")
        p = subprocess.run([SOJA, "-config", conf], capture_output=True,
                           timeout=20, text=True)
        if p.returncode == 0 or want not in (p.stdout + p.stderr):
            raise Fail(f"{uri} was not refused as {want!r}: "
                       f"{p.returncode} {p.stdout}{p.stderr}")
    log("listen schemes: irc://, ws://, http:// for localhost only")


def oauth_section():
    """auth oauth2: a fake authorization server, PLAIN and OAUTHBEARER."""
    import base64
    import http.server
    import json
    import threading

    seen = []

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            seen.append(("GET", self.path))
            if self.path != "/.well-known/oauth-authorization-server/realm":
                self.send_response(404)
                self.end_headers()
                return
            body = json.dumps({
                "issuer": "http://127.0.0.1:9201/realm",
                "introspection_endpoint": "http://127.0.0.1:9201/introspect",
                "introspection_endpoint_auth_methods_supported":
                    ["client_secret_basic"]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0))
            form = self.rfile.read(n).decode()
            seen.append(("POST", form, self.headers.get("Authorization")))
            want = "Basic " + base64.b64encode(b"my+id:p%40ss").decode()
            tok = form.removeprefix("token=")
            ok = self.headers.get("Authorization") == want
            who = {"goodtoken": "carol", "othertoken": "dave"}.get(tok)
            if ok and who:
                body = {"active": True, "username": who}
            elif ok and tok == "nouser":
                body = {"active": True}
            else:
                body = {"active": False}
            data = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 9201), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    port = 6699
    conf = os.path.join(DIR, "oauth.conf")
    with open(conf, "w") as f:
        f.write(f"listen irc+insecure://127.0.0.1:{port}\n"
                f"hostname soja.example.net\n"
                f"db sqlite3 {DIR}/oauth.db\n"
                f"enable-user-on-auth true\n"
                f"auth oauth2 http://my%20id:p%40ss@127.0.0.1:9201/realm\n")
    out = open(os.path.join(DIR, "oauth.log"), "ab")
    p = subprocess.Popen([SOJA, "-config", conf], stdout=out, stderr=out)
    try:
        wait_port(port)
        if seen[0][0] != "GET":
            raise Fail("no discovery request")

        def sasl(mech, payload, nick):
            c = Client(port, f"oauth:{nick}")
            c.send("CAP REQ :sasl")
            c.expect(r"CAP \S+ ACK")
            c.send(f"AUTHENTICATE {mech}")
            c.expect(r"AUTHENTICATE \+")
            c.send("AUTHENTICATE " +
                   base64.b64encode(payload).decode())
            return c

        def bearer(user, tok):
            return (f"n,a={user},\x01auth=Bearer {tok}\x01\x01").encode()

        # OAUTHBEARER, right user
        c = sasl("OAUTHBEARER", bearer("carol", "goodtoken"), "carol")
        c.expect(r" 903 ")
        c.send("NICK carol")
        c.send("USER carol 0 * :x")
        c.send("CAP END")
        c.expect(r" 001 ")
        c.close()
        # no authzid is fine
        c = sasl("OAUTHBEARER", bearer("", "goodtoken"), "carol")
        c.expect(r" 903 ")
        c.close()
        # wrong authzid, inactive token, no username
        for tok, who in (("goodtoken", "dave"), ("badtoken", "carol"),
                         ("nouser", "carol")):
            c = sasl("OAUTHBEARER", bearer(who, tok), "x")
            c.expect(r" 904 ")
            c.close()
        # a malformed initial response
        # (as in soju, go-sasl's error is not an IRC one: the connection ends)
        c = sasl("OAUTHBEARER", b"garbage", "x")
        try:
            c.expect(r" 903 ", timeout=3)
            raise Fail("a malformed OAUTHBEARER response succeeded")
        except Fail as e:
            if "connection closed" not in str(e):
                raise
        c.close()
        # PLAIN: the password is the token
        c = Client(port, "oauth:plain")
        c.register("carol", "carol", "goodtoken")
        c.close()
        c = Client(port, "oauth:plain2")
        c.send("PASS othertoken")
        c.send("NICK carol")
        c.send("USER carol 0 * :x")
        c.expect(r" 464 |ERROR|FAIL")
        c.close()
        if not any(x[0] == "POST" and
                   x[2] == "Basic " + base64.b64encode(b"my+id:p%40ss").decode()
                   for x in seen):
            raise Fail(f"introspection was not authenticated: {seen}")
    finally:
        p.kill()
        srv.shutdown()
    log("auth oauth2: OAUTHBEARER and PLAIN through a fake server")


def http_auth_section():
    """auth http, with the Forwarded headers, beside an oauth2 line."""
    import base64
    import http.server
    import threading

    seen = []

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            seen.append(dict(self.headers))
            user, _, pw = base64.b64decode(
                self.headers.get("Authorization", "Basic ")[6:]
            ).decode().partition(":")
            code = 200 if (user, pw) == ("erin", "pw") else 403
            if user == "broken":
                code = 500
            self.send_response(code)
            self.send_header("Content-Length", "0")
            self.end_headers()

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 9203), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    port = 6702
    conf = os.path.join(DIR, "httpauth.conf")
    with open(conf, "w") as f:
        f.write(f"listen irc+insecure://127.0.0.1:{port}\n"
                f"hostname soja.example.net\n"
                f"db sqlite3 {DIR}/httpauth.db\n"
                f"enable-user-on-auth true\n"
                f"auth http http://127.0.0.1:9203/check\n")
    out = open(os.path.join(DIR, "httpauth.log"), "ab")
    p = subprocess.Popen([SOJA, "-config", conf], stdout=out, stderr=out)
    try:
        wait_port(port)
        c = Client(port, "httpauth:ok")
        c.register("erin", "erin", "pw")
        c.close()
        h = seen[-1]
        fwd = h.get("Forwarded", "")
        if not fwd.startswith('for="127.0.0.1:') or \
                h.get("X-Forwarded-For") != "127.0.0.1":
            raise Fail(f"no Forwarded headers: {h}")
        for user, pw in (("erin", "bad"), ("broken", "pw")):
            c = Client(port, "httpauth:no")
            c.send(f"PASS {pw}")
            c.send(f"NICK {user}")
            c.send(f"USER {user} 0 * :x")
            c.expect(r" 464 |ERROR|FAIL")
            c.close()
    except Exception:
        out.flush()
        print(open(os.path.join(DIR, "httpauth.log"), errors="replace").read()[-1500:])
        raise
    finally:
        p.kill()
        srv.shutdown()
    log("auth http: Basic credentials and Forwarded headers")


def upload_http_section():
    """file-upload http: the file is posted to the backend."""
    import base64
    import http.server
    import threading

    seen = []

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0))
            data = self.rfile.read(n)
            seen.append((dict(self.headers), data))
            if data == b"deny":
                body = b"nope"
                self.send_response(418)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            self.send_response(201)
            self.send_header("Location", "stored/file.bin")
            self.send_header("Content-Length", "0")
            self.end_headers()

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 9204), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    port = 6703
    conf = os.path.join(DIR, "upload-http.conf")
    with open(conf, "w") as f:
        f.write(f"listen irc+insecure://127.0.0.1:{port}\n"
                f"listen http+insecure://127.0.0.1:8085\n"
                f"hostname soja.example.net\n"
                f"db sqlite3 {DIR}/upload-http.db\n"
                f"file-upload http http://127.0.0.1:9204/store\n")
    out = open(os.path.join(DIR, "upload-http.log"), "ab")
    p = subprocess.Popen([SOJA, "-config", conf], stdout=out, stderr=out)
    try:
        wait_port(port)
        subprocess.run([os.path.join(os.path.dirname(SOJA), "..", "sojadb",
                                     "sojadb"),
                        "-config", conf, "create-user", "alice"],
                       input="secret\n", text=True, check=True,
                       capture_output=True, timeout=30)
        import http.client
        auth = "Basic " + base64.b64encode(b"alice/net@dev:secret").decode()

        def post(body, extra=None):
            c = http.client.HTTPConnection("127.0.0.1", 8085, timeout=10)
            h = {"Authorization": auth, "Content-Type": "image/png",
                 "Content-Disposition": 'attachment; filename="a b.png"'}
            h.update(extra or {})
            c.request("POST", "/uploads", body, h)
            r = c.getresponse()
            return r.status, dict(r.getheaders()), r.read()

        st, hd, _ = post(b"hello")
        if st != 201 or hd.get("Location") != "/uploads/stored/file.bin":
            raise Fail(f"upload: {st} {hd}")
        h, data = seen[-1]
        if data != b"hello" or h.get("Soju-Username") != "alice" or \
                h.get("Content-Type") != "image/png" or \
                "a b.png" not in h.get("Content-Disposition", ""):
            raise Fail(f"backend request: {h} {data}")
        st, hd, body = post(b"deny")
        if st != 418 or body != b"nope" or \
                not hd.get("Content-Type", "").startswith("text/plain"):
            raise Fail(f"backend error not passed on: {st} {hd} {body}")
        c = http.client.HTTPConnection("127.0.0.1", 8085, timeout=10)
        c.request("GET", "/uploads/stored/file.bin")
        if c.getresponse().status != 404:
            raise Fail("GET with the http backend should be 404")
    finally:
        p.kill()
        srv.shutdown()
    log("file-upload http: posted to the backend, errors passed on")


try:
    main()
    listen_schemes_section()
    upload_http_section()
    http_auth_section()
    oauth_section()
    pam_section()
    print("E2E PASS")
except Fail as e:
    print(f"E2E FAIL: {e}")
    log("soja log")
    try:
        text = open(os.path.join(DIR, "soja.log")).read()
        print(text[-4000:])
        if os.environ.get("E2E_KEEP_LOG"):
            open(os.environ["E2E_KEEP_LOG"], "w").write(text)
    except OSError:
        pass
    sys.exit(1)
finally:
    if soja_proc and soja_proc.poll() is None:
        soja_proc.kill()
