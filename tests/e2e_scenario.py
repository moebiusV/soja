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
from e2e_client import Client, Fail  # noqa: E402

SOJA = os.environ["SOJA_BIN"]
SOJUCTL = os.environ["SOJUCTL_BIN"]
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
    soja_proc = subprocess.Popen([SOJA, "-config", CONF], stdout=out,
                                 stderr=out)
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

    log("sojuctl and the admin socket")
    sock = os.path.join(DIR, "admin.sock")
    mode = os.stat(sock).st_mode & 0o777
    if mode != 0o600:
        raise Fail(f"admin socket has mode {mode:o}, wanted 600")

    def ctl(*words):
        return subprocess.run([SOJUCTL, "-config", CONF, *words],
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
    h.send("SEARCH in=#u;text=history")
    h.expect(r"BATCH \+\S+ soju.im/search")
    h.close()

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


try:
    main()
    print("E2E PASS")
except Fail as e:
    print(f"E2E FAIL: {e}")
    log("soja log")
    try:
        print(open(os.path.join(DIR, "soja.log")).read()[-4000:])
    except OSError:
        pass
    sys.exit(1)
finally:
    if soja_proc and soja_proc.poll() is None:
        soja_proc.kill()
