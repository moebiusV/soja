# soja

Parent: [All Projects](https://moebiusv.github.io/) | Git Repo: [github.com/moebiusV/soja](https://github.com/moebiusV/soja) | `git clone https://github.com/moebiusV/soja`

soja is a drop-in replacement for [soju](https://soju.im), the user-friendly
IRC bouncer, written from scratch in Ada 2022. The name is a pun:

> soja = **soju**-in-**Ada** — and *we are all sojas now*.

It is a translation of soju from Go to Ada, built on the packages published by
[ada-on-alpine](https://github.com/moebiusV/ada-on-alpine) (aws, gnatcoll-db,
libsodium-ada, mustache-ada, hbnf, …) instead of Go's standard library, so it
runs on Alpine edge (musl).

The upstream Go source is pinned as a git submodule at `upstream/soju` as the
reference for the translation. See `PORTING.md` for the component map and the
behavioural requirements.

## Status

The core bouncer works: `soja` accepts clients on `ircs://` and
`irc+insecure://`, authenticates them against the SQLite database, connects to
the upstream networks, and relays channels, messages, modes, topics, WHO /
WHOIS / MONITOR, kicks and invites, with chat history (`CHATHISTORY`, `SEARCH`)
kept in the database or in ZNC-style log files (`message-store db` / `fs`); BouncerServ manages networks, channels,
SASL and users; `sojadb` creates users and changes passwords.  An end-to-end
check against a real ngircd (`tests/e2e.sh`) covers registering, adding a
network, joining, messaging both ways, a kick that is not undone, replay on
reconnect and a restart.

Not there yet (see `PORTING.md`): the Prometheus and pprof listeners, file upload,
web push, PAM and OAuth 2 authentication, SASL EXTERNAL certificate
generation.
`soja` refuses to start with an authentication driver it cannot honour.

soju bugs found while translating are fixed here and written up, ready to be
sent upstream, in `SOJU-BUGS.md`.

## Build

```
# inside the ada-on-alpine container
gprbuild -P soja.gpr                       # the library
(cd cmd/soja && gprbuild -P soja.gpr)      # the daemon: cmd/soja/soja
(cd cmd/sojadb && gprbuild -P sojadb.gpr)  # cmd/sojadb/sojadb
sh tests/e2e.sh                            # end to end, against ngircd
```

## License

AGPL-3.0, inherited from soju (soja is a translation of soju). See `LICENSE`.
