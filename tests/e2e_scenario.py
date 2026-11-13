"""The Milestone A scenario: soja between a client and a real ngircd."""
import os
import signal
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from e2e_client import Client, Fail  # noqa: E402

SOJA = os.environ["SOJA_BIN"]
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


def direct(nick):
    c = Client(SERVER, f"ngircd:{nick}")
    c.register(nick, nick)
    return c


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
