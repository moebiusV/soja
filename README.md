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
certificate. Reference:

- [docs/soja.1.scd](docs/soja.1.scd): every configuration directive and every
  `BouncerServ` command. [docs/sojadb.1.scd](docs/sojadb.1.scd) and
  [docs/sojactl.1.scd](docs/sojactl.1.scd) are the other two programs. (They are
  [scdoc](https://git.sr.ht/~sircmpwn/scdoc) sources: `scdoc < soja.1.scd | man -l -`.)
- [docs/differences.md](docs/differences.md): where soja differs from soju.
- [PORTING.md](PORTING.md): how the translation is organised, and the
  deviations in detail. [SOJU-BUGS.md](SOJU-BUGS.md): bugs found in soju while
  translating, fixed here and written up to be sent to soju.
- [STYLE.md](STYLE.md): the Ada style the code follows.

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
