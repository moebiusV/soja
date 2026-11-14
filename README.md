# soja

Parent: [All Projects](https://moebiusv.github.io/) | Git Repo: [github.com/moebiusV/soja](https://github.com/moebiusV/soja) | `git clone https://github.com/moebiusV/soja`

soja is a drop-in replacement for [soju](https://soju.im), the user-friendly
IRC bouncer, written in Ada 2022. The name is a pun:

> soja = **soju**-in-**Ada** — and *we are all sojas now*.

It reads soju's configuration file and database, speaks the same IRC
extensions, has the same BouncerServ commands, and keeps soju's default paths,
so an existing soju installation can switch to soja by changing the program.
It is built on the packages published by
[ada-on-alpine](https://github.com/moebiusV/ada-on-alpine) (aws, gnatcoll-db,
bracke-cryptolib, hbnf) and runs on Alpine edge (musl).

## What it does

- Connects to your IRC networks and stays there while your clients come and go;
  each client gets the backlog it missed, with per-client buffers.
- Several users on one bouncer, each with their own networks, channels and
  SASL logins. Networks are managed from IRC by talking to `BouncerServ`, or
  by any client that supports `soju.im/bouncer-networks`.
- Chat history (`CHATHISTORY`, `SEARCH`, read markers) in the database or in
  log files; channels can be detached; Web Push notifications to browsers.
- Listens on TLS and plain TCP, Unix sockets, WebSockets and HTTP; serves file
  uploads and Prometheus metrics; answers ident; understands the PROXY protocol.
- Logs in to networks with SASL PLAIN or with a client certificate it can
  generate itself (`certfp generate`, SASL EXTERNAL).
- Authenticates users against its own database, an OAuth 2.0 server, or PAM.
- `sojadb` creates users, `sojactl` sends commands to a running bouncer.

## Getting started

```
sojadb create-user <username> -admin
soja
```

[docs/getting-started.md](docs/getting-started.md) is a short guide, ending
with an example that connects to OFTC, registers a nick and logs in with a
certificate. The rest is listed under [Documentation](#documentation).

## Documentation

- [docs/getting-started.md](docs/getting-started.md): setting up the server and
  the clients, and the OFTC example
- [docs/soja.1.scd](docs/soja.1.scd), [docs/sojadb.1.scd](docs/sojadb.1.scd),
  [docs/sojactl.1.scd](docs/sojactl.1.scd): the manual pages of `soja`
  (every configuration directive and every `BouncerServ` command), of `sojadb`
  and of `sojactl`, as [scdoc](https://git.sr.ht/~sircmpwn/scdoc) sources
  (`scdoc < docs/soja.1.scd | man -l -`)
- [docs/differences.md](docs/differences.md): where soja differs from soju
- [PORTING.md](PORTING.md): how the translation is organised: the component
  map, the packages used, the decisions and the deviations in detail
- [SOJU-BUGS.md](SOJU-BUGS.md): the bugs found in soju while translating, fixed
  here and written up to be sent to soju
- [STYLE.md](STYLE.md): the Ada style the code follows (a pointer to the shared
  guide)
- [grammars/](grammars/): the hbnf grammars all parsing is done with (IRC
  messages, the configuration file, BouncerServ command lines, JSON, URLs,
  HTTP heads, ident, PROXY, ZNC logs, SASL OAUTHBEARER, media types, byte
  ranges); `grammars/generate.sh` regenerates the parsers
- [tests/](tests/): the unit checks (`*_check.gpr`), the end-to-end scenario
  (`e2e.sh`, `e2e_scenario.py`, `e2e_client.py`) and the IRC parser oracle

## Build

```
# inside the ada-on-alpine container
gprbuild -P soja.gpr                         # the library
(cd cmd/soja && gprbuild -P soja.gpr)        # the daemon: cmd/soja/soja
(cd cmd/sojadb && gprbuild -P sojadb.gpr)    # cmd/sojadb/sojadb
(cd cmd/sojactl && gprbuild -P sojactl.gpr)  # cmd/sojactl/sojactl
sh tests/e2e.sh                              # end to end, against ngircd
```

The unit tests are `tests/*_check.gpr`; each builds a program that prints
`ALL PASS`.

## Status

soja has been tested against a local ngircd (registering, channels, replay on
reconnect, history, read markers, SASL, TLS, file upload, WebSockets, Web Push,
OAuth 2, PAM, restarts) and against fake servers for the rest. It has not yet
been used for long against live networks; reports are welcome.

## License

AGPL-3.0, inherited from soju (soja is a translation of soju). See `LICENSE`.

## References

**The program soja translates**

1. soju, the IRC bouncer: <https://soju.im>; source:
   <https://git.sr.ht/~emersion/soju> (reference revision `6541047`, see
   [PORTING.md](PORTING.md)); its extension specifications are in
   `doc/ext/` of that repository.
2. IRCv3 specifications: <https://ircv3.net/irc/>.

**Standards**

3. RFC 2812, *Internet Relay Chat: Client Protocol*.
4. RFC 4616, *The PLAIN Simple Authentication and Security Layer (SASL)
   Mechanism*; RFC 7628, *A Set of Simple Authentication and Security Layer
   (SASL) Mechanisms for OAuth*.
5. RFC 8414, *OAuth 2.0 Authorization Server Metadata*; RFC 7662, *OAuth 2.0
   Token Introspection*.
6. RFC 8030, *Generic Event Delivery Using HTTP Push*; RFC 8188, *Encrypted
   Content-Encoding for HTTP*; RFC 8291, *Message Encryption for Web Push*;
   RFC 8292, *Voluntary Application Server Identification (VAPID) for Web
   Push*.
7. RFC 6455, *The WebSocket Protocol*; RFC 7239, *Forwarded HTTP Extension*;
   RFC 1413, *Identification Protocol*; the HAProxy *PROXY protocol*
   specification, <https://www.haproxy.org/download/1.8/doc/proxy-protocol.txt>.
8. RFC 8259, *The JavaScript Object Notation (JSON) Data Interchange Format*;
   RFC 4648, *The Base16, Base32, and Base64 Data Encodings*.

**What soja is built from**

9. [ada-on-alpine](https://github.com/moebiusV/ada-on-alpine): the packages
   (and the aport of soja).
10. [hbnf](https://github.com/moebiusV/hbnf): the grammar compiler.
11. [AWS](https://github.com/AdaCore/aws) (sockets, TLS, HTTP) and
    [GNATCOLL](https://github.com/AdaCore/gnatcoll-db) (SQLite).
12. [bracke/cryptolib](https://github.com/bracke/cryptolib): bcrypt, hashes,
    X.509, ECDH, ECDSA, AES-GCM.
13. [ngircd](https://ngircd.barton.de), the server the end-to-end tests run
    against.
14. [OFTC's CertFP page](https://www.oftc.net/NickServ/CertFP/), which the
    getting-started example follows.
