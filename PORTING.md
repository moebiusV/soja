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
| `config/config.go`         | `Soja.Config`     | `hbnf` (scfg grammar)             |
| `conn.go` (TLS, buffering) | `Soja.Conn`       | `aws` (`AWS.Net.SSL`, OpenSSL 3) |
| `certfp.go` (generateCertFP) | `Soja.Certfp`   | **deferred** — X.509 cert creation (see below) |
| `downstream.go`            | `Soja.Downstream` (leaves) + `Soja.Core` (downstreamConn) | — |
| `upstream.go`              | `Soja.Upstream` (leaves) + `Soja.Core` (upstreamConn) | — |
| `server.go`                | `Soja.Server`     | — (Ada tasking)                  |
| `user.go`                  | `Soja.User` (deliveredStore) + `Soja.Core` (user/network) | `bracke-cryptolib` (SHA-256) |
| `service.go`               | `Soja.Service`    | —                                |
| `database/`                | `Soja.Database` + `.Sqlite` | `gnatcoll-db` (SQLite) + `bracke-cryptolib` (bcrypt) |
| `auth/`                    | `Soja.Auth`       | `bracke-cryptolib`, `aws` (oauth2) |
| `msgstore/`                | `Soja.Msgstore`   | `gnatcoll-db`                    |
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

**No new Ada repos are required for v1.** bcrypt, SHA-256, HMAC, base64, and a
CSPRNG are all already in `bracke-cryptolib`; TLS is already in `aws`.

| Go module | Use in soju | Ada replacement |
| --- | --- | --- |
| `crypto/tls` (stdlib) | every TLS socket | `AWS.Net.SSL` (OpenSSL 3, in `aws`) |
| `golang.org/x/crypto/bcrypt` | `internal` auth password hash | `CryptoLib.Bcrypt` (`bracke-cryptolib`) — see `$2a$` note |
| `crypto/sha256` (stdlib) | cert fingerprints (certfp) | `CryptoLib.Hashes` |
| `encoding/base64` (stdlib) | SASL PLAIN payload | `CryptoLib.Base64` |
| `crypto/rand` (stdlib) | bcrypt salt, SASL nonces | `CryptoLib.OS_Random` |
| `github.com/emersion/go-sasl` | SASL PLAIN / EXTERNAL | hand-written (both trivial) |
| `github.com/pires/go-proxyproto` | PROXY protocol | hand-written (small) |
| `modernc.org/sqlite` / `go-sqlite3` | SQLite store | `gnatcoll-db` (SQLite) |
| `github.com/lib/pq` | Postgres store | `gnatcoll-db` (Postgres) |
| `gopkg.in/irc.v4` + `xirc/` | IRC parse/format, caps | `Soja.Irc` (message grammar via `hbnf`, caps/casemapping hand-written) |
| `git.sr.ht/~emersion/go-scfg` | config | `hbnf` (scfg grammar) |
| `nhooyr.io/websocket` | WebSocket transport | hand-written RFC6455 (SHA-1 + base64) |
| `git.sr.ht/~sircmpwn/go-bare` | msgstore fs encoding | hand-written (small) |
| `github.com/prometheus/client_golang` | metrics | `aws` + hand-written text format |
| `github.com/SherClockHolmes/webpush-go` | push | `bracke-cryptolib` + `aws` — defer |
| `github.com/msteinert/pam/v2` | PAM auth | libpam binding — defer |
| `golang.org/x/crypto/ssh/terminal` | sojudb password entry | termios — minor |

### TLS: OpenSSL via `aws`, not GNUTLS/libressl

The ada-on-alpine `aws` package is built `SOCKET=openssl` against **OpenSSL 3**
(`libssl3` / `libcrypto3`, present in the image), so its `AWS.Net.SSL` layer is
the TLS we get for free — for upstream (client) and downstream (server) IRC
sockets alike. LibreSSL/libTLS and GNUTLS are not in the image and would each
mean a new binding + aport; OpenSSL 3 is already there and already wired in, so
it is the ockham choice. Verify `AWS.Net.SSL` handles raw sockets (not just
HTTP) during the `conn.go` translation.

### SASL is PLAIN + EXTERNAL only

soju's SASL support is `PLAIN` (base64 of `\0user\0pass`) and `EXTERNAL`
(client certificate). There is no SCRAM, so no HMAC/PBKDF2 is needed.

### bcrypt `$2a$` vs `$2b$`

Go's bcrypt (which soju uses) emits `$2a$`; bracke's `CryptoLib.Bcrypt` natively
emits and verifies `$2b$`. `bracke-cryptolib` is patched (the `bcrypt-prefixes`
patch in the ada-on-alpine aport, shipped in `ada-toolchain:edge`) so `Verify`
also accepts `$2a$` and `$2y$` for passwords under 72 bytes, where the three
prefixes are byte-identical. soja calls `Verify` directly — no shim. soja writes
`$2b$` only (the default is unchanged); the other prefixes are accepted, never
produced. bcrypt is internal-only — the hash is stored in the DB and compared
in-process, never on the wire.

### SQLite binding: `gnatcoll-db` (gnatcoll-sqlite), and its FTS5 gap

The sqlite3 binding is **gnatcoll-sqlite**, shipped in the `gnatcoll-db` aport
and already installed in the image.  It has two layers: `GNATCOLL.SQL.Sqlite`
(the high-level driver over `gnatcoll-sql`'s `Execute`/`Fetch`) and
`GNATCOLL.SQL.Sqlite.Gnade` (a thin binding to the raw sqlite3 C API, with the
sqlite3 amalgamation bundled into the library).  No new binding or aport is
needed.

Two deviations from Go's `modernc.org/sqlite` store, both forced by
gnatcoll-sqlite:

- **No multi-statement `Execute`.**  gnatcoll prepares one statement per
  `Execute`; Go's driver runs the whole schema/migration blob.  The schema and
  the migrations are therefore split into individual statements (same on-disk
  result).
- **FTS5 is missing.**  The bundled amalgamation is built without FTS5
  (`CREATE VIRTUAL TABLE ... USING fts5` fails with "no such module: fts5").
  soju's `MessageFTS` table + triggers serve only the message store
  (`StoreMessages`/`ListMessages` search), so they are deferred along with
  those methods.  When the message store is ported, FTS5 needs either a rebuilt
  `gnatcoll-db` (`-DSQLITE_ENABLE_FTS5`) or a thin aport against Alpine's
  FTS5-enabled `libsqlite3`.

The message-store methods (`GetMessageLastID`, `StoreMessages`,
`ListMessageLastPerTarget`, `ListMessages`) are deferred until `Soja.Irc`
(`irc.go`) is ported, since they operate on `irc.Message`.

## IRC wire-format quirks (irc.v4 vs RFC 2812 / IRCv3)

soja reproduces `gopkg.in/irc.v4`'s parser/serializer exactly, including where
it deviates from RFC 2812 §2.3 and the IRCv3 specs. These are behaviour to
preserve, not bugs to fix:

- **Command uppercasing** — `ParseMessage` stores the command upper-cased
  (`strings.ToUpper`); RFC 2812 only requires commands be case-insensitive.
- **Trailing/middle param loss** — `String()` emits `" :"` only when the
  trailing param is empty, contains a space, or starts with `:`. A plain-word
  trailing re-emits as a middle param (single space), so the round-trip is not
  byte-exact: `:nick!u@h PRIVMSG #c :hi` → params `["#c","hi"]` →
  `:nick!u@h PRIVMSG #c hi`.
- **Space collapsing** — `ParseMessage` splits middle params with
  `strings.FieldsFunc` on spaces, so runs of spaces collapse; RFC 2812 mandates
  a single SPACE between params.
- **Trailing split** — the trailing param is found by the first `" :"`
  substring, not the RFC's `[ ":" trailing ]` production.
- **Tag order** — Go's `Tags.String()` iterates a map (random order). soja
  emits tags sorted by name instead (deterministic; wire-equivalent).
- **Errors** — four parse errors (zero-length, missing-data-after-tags,
  missing-data-after-prefix, missing-command). Go panics on some malformed
  inputs; soja raises `Parse_Error`.

### IRC message grammar (`hbnf`, jet-free)

The wire message is expressed as an `hbnf` grammar at
`grammars/irc-message.hbnf`; `soja-irc-hbnf.{ads,adb}` walks the generated
parse tree into a `Message`. It is jet-free: the lexer's character classes are
disjoint because each word's class is keyed on its **first byte** — `@`
(message tags), `:` (prefix or trailing start), or anything else (command /
middle param) — so the maximal-munch scanner emits exactly one token per word.

The grammar captures only the structure; the walker applies irc.v4's semantics:
it strips the `@`/`:` markers, splits tags on `;`/`=` and the prefix on
`!`/`@`, upper-cases the command, and re-assembles the trailing param from its
words and their space separators (so interior spaces in the trailing survive).

Deviations (both from keying a word's class on its first byte):

- **`@`- or `:`-leading command / middle param** — irc.v4 treats `@` and `:`
  as markers only at fixed positions, so `PRIVMSG @foo` keeps `@foo` as a
  middle param; the grammar lexes `@foo` as a tags word and rejects it. Rare,
  and arguably malformed.
- **Space only, not whitespace** — faithful, not a deviation: irc.v4 splits on
  `' '` (and `" :"`), never on tabs, so the grammar's `gap` is `1*%x20`.

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

## Open decisions

- **v1 scope**: webpush, PAM, and PostgreSQL are the heavy items; ship
  SQLite-only + internal auth first (soju's default build), then add the rest.
  Decided (2026-10-06): **PostgreSQL is dropped** — the database layer is
  SQLite-only (`gnatcoll-db` SQLite); `database/postgres.go` is not ported.

- **`certfp.go` (`generateCertFP`) is deferred**: it generates a self-signed
  X.509 client certificate for SASL EXTERNAL.  bracke-cryptolib only decodes
  X.509 (no certificate creation), so this needs either a thin aport against
  OpenSSL's X509 API (AWS already ships a partial `ssl-thin__openssl` binding)
  or a pure-Ada X.509 encoder.  Not on the connect-to-IRC critical path.

- **`connectToUpstream` is ported** for `ircs` (TLS via `AWS.Net.SSL` in client
  mode, with `sha-256`/`sha-512` certfp verification of the leaf certificate)
  and `irc+insecure` (plain TCP).  Still deferred within it: **SASL EXTERNAL**
  (client certificate/key — AWS takes cert *file paths*, so the DB blobs need
  a temp-file shim or a low-level `ssl-thin__openssl` binding) and the
  `irc+unix`/`unix` schemes (Unix-domain sockets, needs `GNAT.Sockets`).

- **The upstream connection lifecycle is ported**: `uc.register` (CAP/NICK/
  USER burst), `runUntilRegistered`, `readMessages` (forwarding to the user's
  event queue), and `network.runConn` are wired into `network.run`'s reconnect
  loop.  `uc.handleMessage` is **minimal** — it handles the registration-phase
  messages (PING, CAP LS → CAP END with no caps requested, 001, nick-in-use
  fallback, the registration-error numerics) and defers the ~1400-line
  post-registration dispatch (JOIN/PRIVMSG/NICK/QUIT/MODE/numerics, caps,
  batches, SASL).

- **The downstream registration is ported**: `dc.handleMessageUnregistered`
  (NICK/USER/PASS/AWAY), `dc.register` (internal auth — `GetUser` +
  `CheckPassword`), and `dc.runUntilRegistered`.  Deferred: CAP/SASL/BOUNCER
  negotiation, `dc.welcome` (the welcome burst + network joins + backlog), the
  ~1700-line `dc.handleMessageRegistered` command dispatch, and the
  `server.Handle` glue (`getOrCreateUser`, the connected/disconnected events).

- **Ordering**: `downstream.go`, `upstream.go`, `user.go` and `service.go`
  form one mutually-dependent core (the `network` type in `user.go` holds both
  an `upstreamConn` and downstream connections), so they are ported together,
  not one file at a time.  The connection structs (`user`, `network`,
  `downstreamConn`, `upstreamConn`, `upstreamChannel`) and the event types are
  consolidated in **`Soja.Core`** (Go's single `package soju`), since Ada
  packages cannot be mutually `with`ed the way Go files share one package.
  `msgstore` (message history) and `certfp.go` are supporting, and are not
  needed for a basic connect-to-IRC build.

[soju]: https://soju.im
[ada-on-alpine]: https://github.com/moebiusV/ada-on-alpine
