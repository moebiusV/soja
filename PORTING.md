# Porting notes: soju (Go) → soja (Ada)

soja is a translation of [soju] from Go to Ada 2022, reusing the packages
published by [ada-on-alpine]. The upstream Go source is pinned at
`upstream/soju` (submodule). Keep the translation faithful: same structure,
same logic, same quirks — including observable bugs.

## Component map

| Go (soju)                  | Ada (soja)        | ada-on-alpine package            |
| -------------------------- | ----------------- | -------------------------------- |
| `rate.go` (backoffer)      | `Soja.Backoff`    | — (pure Ada)                     |
| `irc.go` + `xirc/`         | `Soja.Irc`        | — (pure Ada)                     |
| `config/config.go`         | `Soja.Config`     | `hbnf` or hand-written (scfg is tiny) |
| `conn.go` (TLS, buffering) | `Soja.Conn`       | `aws` (GNUTLS) — see TLS below   |
| `certfp.go`                | `Soja.Certfp`     | `aws` + `bracke-cryptolib`       |
| `downstream.go`            | `Soja.Downstream` | —                                |
| `upstream.go`              | `Soja.Upstream`   | —                                |
| `server.go`                | `Soja.Server`     | — (Ada tasking)                  |
| `user.go`                  | `Soja.User`       | `libsodium-ada` (scrypt)         |
| `service.go`               | `Soja.Service`    | —                                |
| `database/`                | `Soja.Database`   | `gnatcoll-db` (SQLite + Postgres) |
| `auth/`                    | `Soja.Auth`       | `libsodium-ada`, `aws` (oauth2)  |
| `msgstore/`                | `Soja.Msgstore`   | `gnatcoll-db`, `bracke-cryptolib` (sha, BARE) |
| `fileupload/`              | `Soja.Fileupload` | `aws`                            |
| `identd/`                  | `Soja.Identd`     | `GNAT.Sockets`                   |
| `cmd/soju`                 | `soju` (main)     | —                                |
| `cmd/sojuctl`              | `sojuctl` (main)  | — (IRC over unix socket)         |
| `cmd/sojudb`               | `sojudb` (main)   | `gnatcoll-db`                    |

## Process & concurrency model

The pinned soju revision is **single-process**: one goroutine per connection,
plus `sync.WaitGroup` / channels / timers for coordination. There is no imsg,
no fork, no `os/exec`, and the `unix+admin` listener is plain IRC over a Unix
socket (sojuctl speaks IRC to it). So `imsg-ada` and `spawn` are **not** used.

Map concurrency to Ada tasking:
- one goroutine per connection → one Ada task per connection;
- `sync.WaitGroup` → a protected counter + rendezvous;
- channels / signal notification → task entries or protected objects;
- `time.AfterFunc` / tickers → `Ada.Real_Time` + timed entry calls.

## Go dependency → Ada

| Go module | Use in soju | Ada replacement |
| --- | --- | --- |
| `gopkg.in/irc.v4` + `xirc/` | IRC parse/format, caps | `Soja.Irc` (translate `xirc/`) |
| `modernc.org/sqlite` / `go-sqlite3` | SQLite store | `gnatcoll-db` (SQLite) |
| `github.com/lib/pq` | Postgres store | `gnatcoll-db` (Postgres) |
| `golang.org/x/crypto/bcrypt` | password hash | **binding needed** (libxcrypt) or port |
| `golang.org/x/crypto/scrypt` | internal auth | `libsodium-ada` (`crypto_pwhash_scryptsalsa208sha256`) |
| `github.com/emersion/go-sasl` | SASL PLAIN/EXTERNAL/SCRAM | `libsodium-ada` (HMAC) + hand-written |
| `github.com/pires/go-proxyproto` | PROXY protocol | hand-written (small) |
| `github.com/SherClockHolmes/webpush-go` | push | `libsodium-ada` (X25519 + AES-GCM) + `aws` + JWT |
| `github.com/prometheus/client_golang` | metrics | `aws` + hand-written text format |
| `nhooyr.io/websocket` | WebSocket transport | hand-written RFC6455 + `aws`/`GNAT.Sockets` |
| `git.sr.ht/~emersion/go-scfg` | config | `hbnf` or hand-written |
| `git.sr.ht/~sircmpwn/go-bare` | msgstore fs encoding | hand-written (small) |
| `github.com/msteinert/pam/v2` | PAM auth | libpam binding, or drop |
| `golang.org/x/time` | rate limiting | hand-written token bucket |

## Behavioural requirements (must preserve / encode)

### Upstream channel (re)join — user-specified (2026-10-05)

- **Do not** auto-rejoin a channel we were **kicked** from.
- **Do not** auto-join when **banned** (`ERR_BANNEDFROMCHAN`) or on other
  persistent failures — bad key (`ERR_BADCHANNELKEY`), invite-only, etc.
- **Channel full** (`ERR_CHANNELISFULL`) is the exception: retry with a
  nagle/exponential backoff (`Soja.Backoff`).
- Otherwise auto-join configured channels **once at startup** (and on upstream
  reconnect), never in a tight loop.

soju's source only relays these numerics to the client and does not retry, so
this rule is written explicitly, not assumed. Reference anchors:
`upstream/soju/upstream.go` (KICK ~1255) and `downstream.go` (JOIN ~1867);
`rate.go` is the backoff primitive.

## Open decisions (flag, do not silently pick)

- **TLS**: soju uses Go `crypto/tls` everywhere; Ada has no stdlib TLS. Likely
  path is `aws`'s GNUTLS socket layer (`AWS.Net.SSL`). Confirm the
  ada-on-alpine `aws` package ships GNUTLS, or add a libssl/gnutls binding.
- **bcrypt**: not in libsodium. Decide port vs. bind to libxcrypt.
- **v1 scope**: webpush, PAM, and PostgreSQL are the heavy items; likely ship
  SQLite-only + internal auth first (soju's default build), then add the rest.

[soju]: https://soju.im
[ada-on-alpine]: https://github.com/moebiusV/ada-on-alpine
