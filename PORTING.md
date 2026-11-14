# Porting notes: soju (Go) → soja (Ada)

soja is a translation of [soju] from Go to Ada 2022, reusing the packages
published by [ada-on-alpine]. The translation is complete (2026-11-14), and soju's
source is no longer carried in this repository: the reference revision was
`6541047` (`v0.8.0-9-g6541047`, 2024-07-04) of
<https://git.sr.ht/~emersion/soju>, the last commit before the project moved
to <https://codeberg.org/emersion/soju>; clone it to compare. Keep the translation
faithful: same structure and logic.  Wire-format quirks of irc.v4 stay (see below).  Clear bugs in soju
itself are fixed, not copied (decided 2026-11-12), and each fix is recorded
here under "Bugs in soju that soja fixes" and, in PR-ready form, in
`SOJU-BUGS.md` (each becomes its own upstream PR once soja is complete).

## What hbnf can do (checked 2026-11-13; read this before deciding a format is "not an hbnf grammar")

Several notes below say hbnf cannot express something because of its "lexer" (the
znclog line, the quoting of BouncerServ's command line, the ident query).  **hbnf
has no lexer.**  It is a scannerless, ordered-choice (PEG) parser generator: a rule
reads characters, a literal is matched where it stands, a repetition takes what it
can, and `!x` / `&x` look ahead.  Text after a delimiter that may contain the
delimiter is the rest of the line (`*~LF`); a delimiter that is the first of its
kind is `*( ~">" | ">" !" " ) "> "`; a class used twice is two uses of one rule.
The notes were written against an older hbnf and its token-and-walker habit; the
grammars it read used the older notation (`language Ada`, `%x09-0D`, maximal-munch
tokens), which the current hbnf refuses.

Where it lives: `/home/matthew/claude/hbnf` (`README.md`, `CONTEXTS.md` for the
newer notation, `decision-register.md` for what was decided and when, `corpus/` for
worked grammars, `tests/` for how each is checked).  Backends: C, Rust, Zig, Ada,
tree-sitter (`hbnf FILE --backend=ada`).  Not every feature is in every backend:
contexts (`in` / `not in` sets) are in all four; facts and rewrites (`=>`) too
(Ada since `d201a6e`).

What was checked, with real grammars and cases (not guesses):

- **znclog** (`corpus/znclog/znclog.hbnf`, `tests/znclog.sh` in the hbnf repo): every
  line kind of `reader.go`'s `UnmarshalLine` with events on, split at the first
  delimiter as `strings.SplitN` does, text free.  A transducer (each line replaced by
  `KIND<TAB>fields`); its output is identical to a Python port of the Go splits on 15
  written lines and 30000 fuzzed ones built from the delimiters (`<a> b> c`,
  `<a>b> x> y`, nested parentheses, quotes).  The Go code itself could not be run (no
  Go toolchain on that machine).
- **ident query** (`<port> , <port>`): `query = *WSP port *WSP "," *WSP port *WSP`,
  `port = 1*DIGIT`: 7 cases, accepts the three good spacings, refuses `6193 23`,
  `6193,`, `,23` and `6193, 23, 5`.  No walker is needed.
- **splitWords' quoting**: `word = 1*( plain | escaped | dq | sq )` with
  `dq = "\"" *( ~( "\"" | "\\" ) | "\\" OCTET ) "\""` (likewise `sq`) accepts and refuses
  what `splitWords` does (8 cases: unterminated quote and trailing backslash are
  errors, `""` is a word, a `'` inside `"` is text).  Not checked end to end: producing
  each word's unquoted value from the grammar (it is a list of pieces, plain, escaped
  and quoted, whose payloads a short walker joins, or a transducer like znclog's).

Done in soja (2026-11-13, hbnf 0.8, `d201a6e`): `Znclog`, `Service_Words`,
`Ident_Query`, the PROXY v1 line and the HTTP head are now read by grammars in the
new notation (`grammars/*.hbnf`, regenerated into `src/` by
`grammars/generate.sh`; the image `ada-toolchain:edge-full-hbnf08` has the tool).
Every grammar of soja is in the new notation now (the older `irc-message`, `scfg`
and `obconf`, with a lexer and a walker, are gone).  Two things about hbnf's Ada
tree came up, for its author:

- A rule made only of character rules is read as one text, whatever its parts
  are named: `field = name ":" value` has no `Name` and `Value` in the tree.
  A record appears when the rule holds something that is not text: an `int`, or
  a lookahead (`&x`, `!x`) of a rule.  The grammars here put a lookahead in
  front of a kind of line (`&"*** "`) where the tree must say which kind it
  is.  (An optional literal, `[ "(" ]`, turns a rule back into text; the
  walkers take parentheses and quotes off, as Go's `TrimPrefix` does.)
- A rule that matches no character fails in a tree of records (`tag-key-only` for an
  empty tag, a prefix of nothing), and the parser takes no empty text at all; a
  list of items that may be empty has to be read as units that each consume
  something.  A rule with a lookahead that repeats, or names a rule that does, is
  one text (the repetition has to be in a rule of its own).  A greedy optional
  before something that can begin the same way (`[ tags ] [ prefix ] rest`) is
  refused; ordered alternatives say it.
- `hidden sep = SP` hides only the first use of `sep`; the second and later
  uses are fields `Sep_2`, `Sep_3`, ...  A number too big for 64 bits is a
  `Constraint_Error` from the parser, not a `Parse_Error`.

If something seems inexpressible, write the small grammar and try it before writing
the note: it takes minutes, and the last three such notes were wrong.

## Component map

| Go (soju)                  | Ada (soja)        | ada-on-alpine package            |
| -------------------------- | ----------------- | -------------------------------- |
| `rate.go` (backoffer)      | `Soja.Backoff`    | — (pure Ada)                     |
| `irc.go` + `xirc/`         | `Soja.Irc.*` (`Messages`, `Modes`, `Helpers`, `Xirc`, `Genmsg`, `Members`, …) | — (pure Ada) |
| `config/config.go`         | `Soja.Config`     | `hbnf` (`grammars/scfg.hbnf`)     |
| `conn.go` (TLS, buffering) | `Soja.Conn`       | `aws` (`AWS.Net.SSL`, OpenSSL 3) |
| `certfp.go` (generateCertFP) | `Soja.Certgen`  | `bracke-cryptolib` X.509 (see "Features added last") |
| `downstream.go`            | `Soja.Downstream` (leaves) + `Soja.Core` (downstreamConn) | — |
| `upstream.go`              | `Soja.Upstream` (leaves) + `Soja.Core` (upstreamConn) | — |
| `server.go`                | `Soja.Server`     | — (Ada tasking)                  |
| `user.go`                  | `Soja.User` (deliveredStore) + `Soja.Core` (user/network) | `bracke-cryptolib` (SHA-256) |
| `service.go`               | `Soja.Service`    | —                                |
| `database/`                | `Soja.Database` + `.Sqlite` | `gnatcoll-db` (SQLite) + `bracke-cryptolib` (bcrypt) |
| `auth/`                    | `Soja.Auth`       | `bracke-cryptolib`, `aws` (oauth2) |
| `msgstore/`                | `Soja.Msgstore` (+ `.Memory`; `.FS`/`.DB` later) | `gnatcoll-db` |
| `fileupload/`              | `Soja.Fileupload` | `aws`                            |
| `identd/`                  | `Soja.Identd`     | `GNAT.Sockets`                   |
| `cmd/soju`                 | `soju` (main)     | —                                |
| `cmd/sojuctl`              | `sojactl` (main)  | — (IRC over unix socket)         |
| `cmd/sojudb`               | `sojudb` (main)   | `gnatcoll-db`                    |

## Process & concurrency model

The pinned soju revision is **single-process**: one goroutine per connection,
plus `sync.WaitGroup` / channels / timers for coordination. There is no imsg,
no fork, no `os/exec`, and the `unix+admin` listener is plain IRC over a Unix
socket (sojactl speaks IRC to it). So `imsg-ada` and `spawn` are **not** used.

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
| `encoding/base64` (stdlib) | SASL PLAIN payload, msg IDs | `Soja.Base64` (hand-written: std/URL alphabets, padded/raw) — `CryptoLib.Base64` is a *private* child and unpadded, so it is not usable |
| `crypto/rand` (stdlib) | bcrypt salt, SASL nonces | `CryptoLib.OS_Random` |
| `github.com/emersion/go-sasl` | SASL PLAIN / EXTERNAL | hand-written (both trivial) |
| `github.com/pires/go-proxyproto` | PROXY protocol | hand-written (small) |
| `modernc.org/sqlite` / `go-sqlite3` | SQLite store | `gnatcoll-db` (SQLite) |
| `github.com/lib/pq` | Postgres store | `gnatcoll-db` (Postgres) |
| `gopkg.in/irc.v4` + `xirc/` | IRC parse/format, caps | `Soja.Irc` (message grammar via `hbnf`, caps/casemapping hand-written) |
| `git.sr.ht/~emersion/go-scfg` | config | `hbnf` (`grammars/scfg.hbnf`) |
| `nhooyr.io/websocket` | WebSocket transport | hand-written RFC6455 (SHA-1 + base64) |
| `git.sr.ht/~sircmpwn/go-bare` | msgstore message IDs (and the fs store's encoding) | `Soja.Bare` (hand-written: uint, int, string) |
| `github.com/prometheus/client_golang` | metrics | `aws` + hand-written text format |
| `github.com/SherClockHolmes/webpush-go` | push | `Soja.Webpush` (`bracke-cryptolib` + `aws`) |
| `github.com/msteinert/pam/v2` | PAM auth | `Soja.Auth.Pam` (libpam through `dlopen`) |
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

### SQLite binding: `gnatcoll-db` (gnatcoll-sqlite), against the system SQLite

The sqlite3 binding is **gnatcoll-sqlite**, shipped in the `gnatcoll-db` aport.
It has two layers: `GNATCOLL.SQL.Sqlite` (the high-level driver over
`gnatcoll-sql`'s `Execute`/`Fetch`) and `GNATCOLL.SQL.Sqlite.Gnade` (a thin
binding to the raw sqlite3 C API).  No new binding is needed.

**The aport builds it against Alpine's own `libsqlite3`**
(`GNATCOLL_SQLITE=external`, `-lsqlite3`), not against the amalgamation that
ships in the gnatcoll-db source.  That bundled copy is SQLite **3.21.0**
(2017): no FTS5 (`CREATE VIRTUAL TABLE ... USING fts5` fails with "no such
module: fts5"), no upsert (`ON CONFLICT`, which soju's `StoreMessages` uses),
no window functions, `RETURNING`, `DROP COLUMN`, JSON or math functions, and no
security fixes since.  With the system library soja has what soju's Go drivers
have (FTS5 included) and every option Alpine enables, and it follows Alpine's
updates.  `tests/sqlite_features_check` guards this: it runs FTS5, upsert,
window functions, `RETURNING`, `DROP COLUMN`, JSON and math functions, checks
the feature options of Alpine's library, and fails on the bundled build.  soja
therefore needs `sqlite-libs` at run time (`sqlite-static` to link it
statically).

One deviation from Go's `modernc.org/sqlite` store remains, forced by
gnatcoll-sqlite:

- **No multi-statement `Execute`.**  gnatcoll prepares one statement per
  `Execute`; Go's driver runs the whole schema/migration blob.  The schema and
  the migrations are therefore split into individual statements (same on-disk
  result).

soju's `MessageFTS` table + triggers serve only the message store
(`StoreMessages`/`ListMessages` search); they are created with it.  The
message-store methods (`GetMessageLastID`, `StoreMessages`,
`ListMessageLastPerTarget`, `ListMessages`) are still to be ported.

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

### IRC message grammar (`grammars/irc-message.hbnf`)

`Soja.Irc.Messages.Parse_Message`, `Parse_Tags` and `Parse_Prefix` are read by
the parsers hbnf makes of `grammars/irc-message.hbnf` (three roots of one
file: the message, a list of attributes written like tags for the BOUNCER
commands, and a prefix on its own), and `Soja.Irc.Hbnf` takes the tree to a
`Message`: it takes the backslash escapes off tag values, upper-cases the
command and picks the prefix apart.  The grammar is irc.v4's `ParseMessage`
written out, quirks included: one space ends the tags word and the prefix word
(a second one is part of the rest), a rest that begins with ` :` has no command
of its own (its trailing text is the command), runs of spaces separate the
parameters, and a line with no command is refused.  `tests/irc_oracle.adb`
keeps the hand-written reading this replaced, and `irc_fuzz_check` makes
120000 lines from the delimiters (and bytes that are not UTF-8) and checks the
two agree on every one, errors included.

An IRC line is bytes, not always UTF-8, and the parser reads code points: bytes
that are not UTF-8 are carried through as private-use characters
(`Soja.Utf8.Escape_Invalid`, `Restore`) and come out as they went in.  (Text
that really has U+F780 .. U+F7FF comes back as bytes: a rarity.)  The parser
takes no empty text, so an empty attribute list and an empty prefix are
special-cased, and a record rule must consume a character, so a list of tags is
read as units (an empty item with its `;`, an item with its `;`, a last item)
and the walker adds the empty item of `""` and of a last `;`.

The old grammar (a token for each word, keyed on its first byte) rejected a
command or middle parameter that began with `@` or `:`; this one does not.

### The configuration file (`grammars/scfg.hbnf`)

`Soja.Config.Parse` reads the file with the parser of `grammars/scfg.hbnf`:
go-scfg's syntax as soju reads it, one directive on a line, `#` comments, a
bareword (anything but blank space, quotes and `#`, a backslash taking the next
character) or a "double" or 'single' quoted string, a line that may end the
file without its line end.  The old grammar widened a lexer's bareword
characters (letters, digits and a few signs); this one takes any, as go-scfg
does, so a path with parentheses or a comma is a word now.  A word does not
touch a quote (`a"b"` is an error, as in go-scfg), a string does not go over a
line, and single quotes work.  Still a deviation: a `#` after a word starts a
comment (go-scfg takes it for part of a word), and there are no blocks.
A file with bytes that are not UTF-8 is read with them kept as they are.

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
soju's `upstream.go` (KICK ~1255) and `downstream.go` (JOIN ~1867);
`rate.go` is the backoff primitive.

### Registered-client dispatch (`Soja.Core.Downstream_Commands`)

Step 7 of Milestone A: `downstream.go` `handleMessageRegistered`, in three
slices (7a PING..NAMES + default forward; 7b WHO/WHOIS with WHOX and the
user-info cache; 7c PRIVMSG/NOTICE/TAGMSG, INVITE, AUTHENTICATE, REGISTER/
VERIFY, AWAY, INFO, MONITOR).  Deviations from the Go layout:

- BouncerServ is a hook (`Service_Handler`); the default answers "not
  available yet" until `service.go` is ported (step 9).
- A bouncer-wide `NOTICE $*` goes through `Broadcast_Hook`; with no hook it
  reaches only the sender's own user until the server's user table exists
  (step 8).
- BOUNCER, CHATHISTORY, READ, SEARCH and WEBPUSH are Milestone B and fall
  through to the default (forward upstream / 421).

### Server glue (`Soja.Bouncer`)

Step 8: server.go's user table, `Handle`, `getOrCreateUser`, `createUser`,
`Start` and the second half of `Shutdown`.  `Soja.Server` sits below
`Soja.Core`, so this is a separate package above it.  Deviations:

- One bouncer per process: `Soja.Server.Handler` takes no context, so
  `Handle` finds the bouncer `Initialize` registered.
- Each user runs on its own task (`User_Runner`) that leaves the table when
  `Core.Run` ends; Go's `stopWG` is `Wait_Group`.
- `Shutdown` is called after `Soja.Server.Shutdown` (which closes the
  listener); it stops users one by one with a timeout, then closes the DB.
- The inactive-user loop, web push config and metrics from `Start` are not
  ported (Milestone B); `HandleAdmin` likewise.

### BouncerServ's command line (`grammars/service-words.hbnf`)

`splitWords` is `Soja.Service_Words.Split_Words`.  The grammar reads the
line as white space and words; a word is pieces run together (plain text, a
backslash and the character after it, a "double" or 'single' quoted string); two
more pieces stand for what Go refuses (a quote never closed, a backslash at
the end), so the messages are Go's.  The walker takes the quotes and
backslashes off and joins the pieces.  White space is Go's `unicode.IsSpace`
(U+0085, U+00A0 and the other Unicode spaces too).  Deviation: bytes that are not
UTF-8 are refused ("failed to parse command"), where Go makes each a U+FFFD.

### BouncerServ commands (`Soja.Core.Service`, `Soja.Flags`)

Step 9: `service.go`.  The command tree is a table of nodes built at
elaboration; prefix matching, `help`, the admin/global rules and the output
(`BouncerServ` PRIVMSGs; errors as `error: ...`) are as in Go.  `Soja.Flags`
ports the parts of Go's `flag` the commands use, with its error texts.
Deviations:

- `certfp generate` and `certfp fingerprint` both work (see "Features added
  last").
- The user table is reached through `Service.Directory`, which `Soja.Bouncer`
  implements, since the table lives above `Soja.Core`.
- `user update -password ""` is refused (Go stores the hash of the empty
  password); `user create` already required a non-empty one.
- `user run` waits at most 30 s for the other user's task (Go waits for the
  context, which has no deadline).
- `server status` reads the gauges of `Soja.Server` (downstreams, upstreams).

### `soju.im/bouncer-networks` (`BOUNCER` for registered clients)

`Cmd_Bouncer` in `Soja.Core.Downstream_Commands`: LISTNETWORKS, ADDNETWORK,
CHANGENETWORK, DELNETWORK, with `updateNetworkAttrs` /
`networkAddrFromAttrs`.  (BIND before registration was already in the
handshake; the caps and the state notifications existed.)  One deviation:
an IPv6 host is bracketed when the address is rebuilt (SB-13).

### identd (`Soja.Identd`, `ident://` listener)

`identd/identd.go`: a store of (server host, server port, our port) -> ident,
and an RFC 1413 server answering `<port>, <port>` queries.  `Soja.Core` registers
each upstream connection right after the TCP connect and before the TLS
handshake (the server may query at once) and removes it when the connection
ends; the ident is the hash of the user ID (`userIdent`).  The query line is
read by `grammars/ident-query.hbnf` (`*WSP local *WSP "," *WSP remote *WSP`), and
the walker checks that the ports are 1 to 65535.  Deviations: a signed port such as `+80` is
refused (Go's `Atoi` takes it); the PROXY protocol wrapper Go puts on the ident
listener is not ported (no PROXY support yet).

### Inactive users (`Soja.Bouncer`)

`server.go`'s `disableInactiveUsersLoop` / `disableInactiveUsers`: a task started
by `Bouncer.Start` wakes every `Inactive_Check_Interval` (4 h), and disables the
users whose last client was longer ago than `disable-inactive-user`, unless they
have a client now (`Num_Downstream_Conns`, now an atomic: the user's task writes
it).  The disable goes through the user's own task (`User_Update_Event`).
Deviations: already-disabled users are skipped, the log says "disabled", and a
failure on one user does not stop the others (SB-14).

### `sojactl` and the admin socket (`Soja.Unix_Server`, `Soja.Conn.Unix`)

`cmd/sojuctl` sends `BOUNCERSERV :<quoted words>` to the `unix+admin://[path]`
listener (default `/run/soju/admin`) and prints the PRIVMSGs that come back;
`Bouncer.Handle_Admin` is `Server.HandleAdmin`: the command runs as an
administrator without a user (so `user run <name> ...` for per-user commands),
and ends with `BOUNCERSERV OK` or `FAIL BOUNCERSERV :<error>`.  AWS.Net is TCP
only, so unix sockets are `GNAT.Sockets` (`Soja.Conn.Unix` is the transport,
`Soja.Unix_Server` the accept loop); `unix://` (clients, mode 0775 as soju sets it, created that way rather than
chmodded) uses the same pieces with `Bouncer.Handle`.
Deviations:

- Go chmods the admin socket to 0600 *after* listening ("TODO: this is racy");
  soja creates it with 0600 (the umask is narrowed around `bind`), so it is
  never reachable with other permissions.
- The socket file is removed when serving ends, as closing a Go UnixListener
  does; like Go, a leftover file from a crash makes the next start fail.
- A unix descriptor is closed once, after both `Close` and the reader's
  end-of-stream (closing it at the end of the stream alone let the later
  `Close` hit a descriptor number reused by a new connection).
- `sojactl` quotes words with the same Go-style `%q` as Go; a word holding a
  control character (a newline, a tab) comes out as the letter after the
  backslash, because BouncerServ's word splitting has no `\n`.

### PROXY protocol (`Soja.Proxy_Protocol`, `accept-proxy-ip`)

`proxyProtoListener` in `cmd/soju/main.go` (go-proxyproto, policy USE for peers
in `accept-proxy-ip`, 5 s header timeout).  A connection from such a peer may
start with a PROXY header, version 1 (text) or 2 (binary); if it does, the
address in it becomes the connection's remote address (the client's hostname,
the log lines, the ident match), and if it does not the connection goes on as
it is.  A malformed header, EOF inside one, or no complete header in 5 s drops
the connection.  Applies to the TCP listeners (ircs, irc+insecure, ident); unix
sockets are never proxied, as in Go.  Version 1 is read by
`grammars/proxy-v1.hbnf` (`PROXY <TCP4|TCP6> src dst sport dport`, or `PROXY UNKNOWN
...`); the walker checks the addresses are of the family and the ports in range.  Version
2 is binary, so it is parsed by hand.  Notes:

- For `ircs://` the header is read *inside* the TLS stream: Go wraps the TLS
  listener in the proxy listener, so soja does the same.
- The header is read on the connection's own task, not in the accept loop, so
  a slow peer cannot hold up other clients.
- A trusted peer that waits for the server to speak first would wait 5 s for
  its header-or-data decision; IRC clients speak first, so it does not matter.
- The destination address of a header is parsed and ignored (Go uses it for
  `LocalAddr`, which soju only reads for upstream connections).
- Fixed on the way: `Soja.Config`'s CIDR parser returned at the first `:`, so
  every IPv6 `accept-proxy-ip` / `upstream-user-ip` network was stored as `::`.

### The database message store, `CHATHISTORY` and `SEARCH`

`message-store db` keeps each user's messages in the soju database
(`msgstore/db.go`): `Soja.Msgstore.Db` over the new `Message` methods of
`Soja.Database` (`Get_Message_Last_ID`, `Store_Messages`, `List_Messages`,
`List_Message_Last_Per_Target`, with the FTS5 search).  The store interface
gained `List_Targets`, `Load_Before_Time`, `Load_After_Time` and `Search`
(Go's optional `ChatHistoryStore` / `SearchStore`, found by type assertion;
here `Supports_Chat_History` / `Supports_Search` say which a store has).  The
registered-client commands are `CHATHISTORY` (TARGETS, LATEST, BEFORE, AFTER,
BETWEEN; not AROUND, as in Go) and `SEARCH`, in
`Soja.Core.Downstream_Commands`, with Go's order of checks and replies.

- The schema creates `MessageFTS` and its three triggers (soju's, to the
  letter), and a database that soja made before FTS5 was available gets them,
  with its existing messages indexed, when it is opened; the file stays valid
  for soju.
- Search text is quoted word by word, as soju does; "word" is a Unicode
  letter, digit or private-use character (via `Ada.Wide_Wide_Characters`, not
  Go's `unicode.In`: marks and the odd number category differ).
- The file store is the next section.
- `gnatcoll-db` needed a fix first: `Close` finalized every statement SQLite
  listed on the connection, including those an FTS5 table owns, so closing any
  connection with an FTS5 table crashed.  The aport carries the patch
  (`testing/gnatcoll-db/close-virtual-table-statements.patch`, written up in
  `docs/bugs/gnatcoll-db-close-vtab/` of ada-on-alpine) and soja's tests need
  that package.
- Fixed soju quirks: SB-15 (targets with only events listed with the zero
  time) and SB-16 (`SEARCH` fails when its text has no word).

### The file message store (`message-store fs <path>`)

`msgstore/fs.go` and `znclog`: `Soja.Msgstore.Fs` and `Soja.Msgstore.Znclog`.
Messages are logged in ZNC's layout and format,
`<root>/<user>/<network>/<target>/<year>-<month>-<day>.log`, one
`[12:34:56] <nick> text` line each (days and times are local), so other tools
can read and write the same logs.  A message's ID is its date and the byte
offset of its line in that day's file.  It has chat history, search (a scan of
the files, case-insensitive) and the network rename hook (`Update_Network`
moves the directory).  As in soju: history walks day by day and gives up after
100 days without a log; the targets are the directories and their time is the
files' modification time (second granularity), and their names are the
*escaped* names (`/` and `\` become `-`), which cannot be turned back.

- Directories are created 0750 and files 0640 with `mkdir`/`creat` (less the
  umask), not fixed afterwards.  All file access is through the C library: GNAT
  refuses to open one file twice in different modes, and the store reads a
  day's log while it has it open for appending.
- `Znclog` reads a line with `grammars/znclog.hbnf`, the line rules of hbnf's
  `corpus/znclog/znclog.hbnf` (checked there against the Go splitting on 30000
  fuzzed lines) with a rule for each kind of line; the walker takes the
  parentheses and quotes off the mask, the reason and the topic and builds the
  message.  (It was hand-parsed first, on the wrong belief that hbnf could not
  express it.)  A line that does not start with a time is an error that fails
  the whole read of that day, as in soju; bytes that are not UTF-8 are replaced
  by U+FFFD first, so that they do not.
- Search lower-cases Unicode text (`Ada.Wide_Wide_Characters`), not only ASCII.
- Fixed soju quirks: SB-17 (rename of a network with no logs reported as an
  error) and SB-18 (the store kept the user's nick from creation; it is told
  of updates).

### WebSocket and HTTP listeners (`Soja.Web`, `Soja.Conn.Ws`, `Soja.Http`)

`wss://` (default port 443), `ws+insecure://` (80) and `ws+unix://` serve a
WebSocket upgrade on any path, as `Server.ServeHTTP` does; `https://`,
`http+insecure://` and `http+unix://` route like cmd/soju's mux: `/socket` is
the WebSocket, `/uploads` and `/uploads/...` are the file-upload handler,
anything else is a 404 (see "File upload" for `/uploads`; without
`file-upload` it answers 404 after the CORS check, as soju does).  nhooyr.io/websocket's rules are kept: HTTP/1.1, a GET with `Connection:
Upgrade` and `Upgrade: websocket`, version 13, a key (426, 405 and 400
otherwise); the Origin must be the request's host or match an `http-origin`
pattern (`Soja.Glob`, Go's `path.Match`, compared without regard to case), else
403; subprotocol `text.ircv3.net` when offered; no compression; messages up to
32768 bytes; one IRC message per text frame, invalid UTF-8 refused (1007) on
the way in and replaced by U+FFFD on the way out.  Behind a trusted proxy
(`accept-proxy-ip`) the client address comes from `Forwarded` (`for`) or
`X-Forwarded-For`.  The framing, the handshake and the SHA-1/base64 are hand
written over `Soja.Byte_Stream` (TCP, TLS and unix sockets alike).

Deviations: one request per connection (Go keeps HTTP connections alive);
no closing-handshake wait on `Close` (the close frame is sent, then the socket
is shut); `Forwarded` is parsed the way `mime.ParseMediaType` does, but only for
the `for` parameter; the Origin is split into host with a small URL reader, not
`net/url` (a control character or space is refused).  The request line and
header fields are read by `grammars/http-head.hbnf` (a request line or a
field, one line at a time; the reader cuts the head into lines).  A field value
that is not UTF-8 is refused, where net/http keeps its bytes.

The socket is released once the connection is closed, the handler has
returned and no task is inside a read or write, so a late write from the writer
task finds the connection closed, not a freed socket.

**Listener robustness (a soja bug, fixed with this change).**  `Server.Serve`
let one exception end the accept loop: a client that connected and reset made
`Peer_Addr` fail ("Socket not connected") and the listener stopped accepting
for good.  Error paths also left descriptors open (`AWS.Net.Free` only frees
memory; `Shutdown` closes the descriptor), so resets used up the process's
descriptors.  A connection that fails setup is now dropped and the loop goes
on; the end-to-end test sends more resetting connections than the default
descriptor limit and checks the listeners still serve.

### File upload (`Soja.Fileupload`, `file-upload fs <dir>`)

`fileupload/`: the `/uploads` handler of the HTTP listeners (`https://`,
`http+insecure://`, `http+unix://`), and the `soju.im/FILEHOST` ISUPPORT token
(`<http-ingress>/uploads`, as before).  `POST /uploads` with a Basic
`Authorization` (the user's password, checked as SASL PLAIN is) stores the body
as `<dir>/<user>/<random>-<name>` (directories 0700, files 0600, created with
`O_EXCL`) and answers 201 with the address in `Location`; `GET`/`HEAD`
`/uploads/<user>/<file>` send it back (`Content-Disposition` inline for the
types a browser may show safely, `attachment` for the rest; SVG and HTML are
never inline); `OPTIONS` answers 204; CORS as in Go.  The limit is 50 MiB.  The
type is read from the extension (Go's built-in table) and else from the content
(`http.DetectContentType`: the common signatures).  `Content-Type` and
`Content-Disposition` go through `grammars/media-type.hbnf`, a `Range` header
through `grammars/http-range.hbnf`.

Deviations: a chunked request body is refused (411); conditional requests
(`If-Modified-Since`, ...) are not handled; several byte ranges at once are
answered with the whole file (Go sends multipart/byteranges); a Bearer token
is checked with the oauth2 driver, and refused with the others; the system's `mime.types` is not read,
so fewer extensions are known (the rest are sniffed); an RFC 2231 continuation
(`filename*0=`) is not joined; the sniffing covers the usual signatures, not all
of WHATWG's; `O_EXCL`/`O_CREAT` are the Linux values.  A request over 50 MiB
is answered at once, without reading it.  Fixed soju bug: SB-19.

Also fixed on the way (soja's own): the default `http-ingress` was made from
the machine's name when the defaults were created, not from the `hostname`
directive, so `FILEHOST` named the wrong host.

### Prometheus metrics (`Soja.Metrics`, `http+prometheus://`)

`http+prometheus://localhost:<port>` serves the text exposition format on
any path, plain HTTP, host `localhost` only (as in soju; a port is required).
The nine `soju_*` metrics of `registerMetrics` are there: gauges
`soju_users_active`, `soju_downstreams_active`, `soju_upstreams_active` and
counters for messages in and out of each side, `soju_upstream_connect_errors_total`
and `soju_worker_panics_total`.  Counting is done by `Soja.Conn` (a message
read, a message queued for writing), set per connection in `Conn_Options`.
Deviations: only the `soju_*` metrics (no `go_*`, `process_*` or `promhttp_*`
ones: there is no Go runtime), values are written as integers (the client
library writes floats, `1e+06` for a million), no OpenMetrics negotiation, and
`soju_worker_panics_total` stays 0 (a failing task logs and ends).  The pure
part, `Render`, is an expression function over a snapshot; the counters are one
protected object.  `http+pprof://` is Go's profiler and has no counterpart.

### Read markers (`READ` / `MARKREAD`)

`Cmd_Read` in `Soja.Core.Downstream_Commands` (`downstream.go`'s `READ`,
`MARKREAD`): the position up to which a client has read a target, kept per
network and target in the `ReadReceipt` table (already there) and shared by
all of the user's clients on the network.  `MARKREAD <target>` asks; with
`timestamp=<time>` it moves the marker forward (never back, never into the
future: the time is clamped to now) and tells every client of the network, each
in its own dialect (`MARKREAD` for `draft/read-marker`, `READ` for
`soju.im/read`; a client with neither is sent nothing, the check being on what
goes out, as in Go).  The channel replay on join already sent the marker.
BouncerServ keeps none (always `*`).  Not ported: the web push notification
soju sends when a marker clears a pending push target is sent as well (see
"Features added last").

### Executables (`cmd/soja`, `cmd/sojadb`) and the end-to-end check

Step 10.  `soja` (main unit `Soja_Main`, since `Soja` is the library's root
package; the project renames the executable) is `cmd/soju/main.go`: flags
`-config`, `-listen` (repeatable), `-debug`; SIGINT/SIGTERM shut down in order,
SIGHUP reloads the configuration (`pragma Interrupt_State (SIGINT, User)` in
`cmd/soja/soja.adc`, because GNAT reserves SIGINT).  `sojadb` is
`cmd/sojudb/main.go` (`create-user`, `change-password`; the password is read
without echo through `stty`).  The default config path is `/etc/soju/config`.
What it refuses or changes, loudly:

- Listeners: `ircs://`, `irc+insecure://`, `unix://`, `ident://`,
  `unix+admin://`, the WebSocket ones (`wss://`, `ws+insecure://`,
  `ws+unix://`) and the HTTP ones (`https://`, `http+insecure://`,
  `http+unix://`), `http+prometheus://localhost:<port>`; any other scheme
  (pprof) is a startup error.
  `accept-proxy-ip` (PROXY protocol) works on the IRC TCP listeners.
- Auth drivers: `internal`, `oauth2` and `pam` work; anything else is a startup
  error: a bouncer that cannot check passwords must not start as if it could.
- All three message stores (`memory`, `db`, `fs`) work;
  only the SQLite database driver.
- SIGHUP re-reads the TLS certificate and key (`Server.Reload_TLS`): new TLS
  connections use the new pair, open ones keep theirs.  A pair that does not
  load (missing, unparsable, mismatched) fails the reload, as in Go, and the
  old one stays; the same check now runs at startup.  AWS does not reference-
  count its SSL config, so the replaced one is left allocated (a few KB per
  reload) rather than freed under connections that still use it.

`tests/e2e.sh` (inside the toolchain container) builds both programs, starts
ngircd and soja, and runs `tests/e2e_scenario.py`: register, create a network
through BouncerServ, join, messages both ways, a kick that is not undone,
replay on reconnect without a new upstream JOIN, and a restart that rejoins
once.  It passes.

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

- **`irc.go` and `xirc/xirc.go` + `genmsg.go` are ported** (`Soja.Irc.Modes`,
  `.Helpers`, `.Xirc`, `.Genmsg`; `userModes` was already `.User_Modes`).
  Helpers that in Go take a `downstreamConn`/`upstreamConn` take only the datum
  they read (`Format_Member_Prefix` takes the multi-prefix flag,
  `Strip_Member_Prefixes`/`Apply_Channel_Modes` the available memberships and
  mode-type table), so these packages do not depend on `Soja.Core`; the
  `Core` upstream-channel record gets its `modes`/`Members` fields (type
  `Soja.Irc.Modes.Channel_Modes` / `Soja.Irc.Members.Member_Maps.Map`) next.
  Deviations from Go:
  - `channelModes.Format` iterates a Go map (random order); soja sorts by mode
    letter (wire-equivalent, deterministic), like the tag-order note above.
  - `GenerateJoin` sorts the caller's slices in place in Go; `Generate_Join`
    sorts a copy.  No Go caller relies on the side effect.
  - `stripMemberPrefixes` is byte-wise; Go maps runes and compares `byte(r)`.
    Identical for the ASCII WHO flags it is applied to.
  - `parseChatHistoryBound` rejects years outside `Ada.Calendar`'s
    1901..2399 (Go accepts 0..9999); it otherwise follows `time.Parse` for the
    server-time layout, including its 1-or-2-digit hour and `,` as the
    fraction separator.
  - `isWordBoundary`/`isHighlight` use `Ada.Wide_Wide_Characters.Unicode`'s
    categories for `unicode.IsLetter`/`IsNumber` (same categories; the
    Unicode version may differ from Go's tables).  `isHighlight` keeps Go's
    quirk that the left context is relative to the re-sliced remainder
    after a miss, so `"bobbob"` highlights `bob`.
  - `Parse_CTCP_Message` upper-cases the command ASCII-only.

- **`Soja.Core`'s deferred record fields are filled** (except `user.msgStore`,
  which arrives with the message store).  Added: `upstreamConn`
  availableChannelModes/isupport/batches/monitored/SASL client state/
  pendingCmds/regain-nick state, `upstreamChannel` modes/Members/detachTimer,
  `downstreamConn` sasl/monitored, `network` pushTargets/lastError.
  - `time.AfterFunc`/`Reset`/`Stop` is **`Soja.Timers`**: one task per timer
    running a tagged `Action` (Go's closure).  Timers must be `Stop`ped (which
    frees them), since a live timer task blocks program exit.  Used by
    `Update_Auto_Detach` and the regain-nick timer (`Start_`/`Stop_Regain_
    Nick_Timer`, `Try_Regain_Nick`).
  - Go's non-blocking `select { case ch <- e: default: }` is
    `Event_Queue.Try_Enqueue` (the regain-nick timer uses it; the detach timer
    keeps Go's blocking send).
  - `Soja.Server` gained `Server_Config` / `Config` / `Set_Config` (soju's
    `Config`, swapped whole like Go's `atomic.Value`).  Go's `Auth` and
    `FileUploader` objects are represented by the auth *driver name* and a
    has-uploader flag, which is all the core asks of them; `Server_SASL_
    Mechanisms` maps driver -> mechanisms (internal/pam: PLAIN; oauth2: PLAIN +
    OAUTHBEARER).  `New_Downstream_Conn` now sets the `sasl` cap value and, for
    the `fs`/`db` message stores, `draft/chathistory` and `soju.im/search`.
  - `downstreamSASL.oauthBearer` and go-sasl's server/client objects are
    reduced to the data soja needs (PLAIN/EXTERNAL mechanism + credentials);
    OAUTHBEARER arrives with oauth2 auth.
  - Bug fixes found on the way: `Net_IRC_Conn.Remote_Addr` returned
    `"1.2.3.4: 6667"` (stray space from `Positive'Image`) and did not bracket
    IPv6; and `newDownstreamConn`'s `net.SplitHostPort` fallback is now
    honoured (`hostname` is the host part, not `host:port`).
  - Test note: an unclosed `Soja.Conn.Conn` keeps its writer task blocked and
    the program alive, so tests that build connections must `Close` them.

- **The message store interface and the in-memory store are ported**
  (`Soja.Msgstore`, `Soja.Msgstore.Memory`), with the BARE message-ID codec
  (`Soja.Bare`, `Soja.Base64`) so IDs are byte-compatible with soju's (they
  matter for the fs store, whose IDs are persisted).  `Core.User.Msg_Store` is
  set from the `Msg_Store_Driver` config ("memory" only; "fs"/"db" leave it
  null until those stores exist) and `uc.appendLog` is `Core.Append_Log`.
  Not ported yet: Go's optional store interfaces (`ChatHistoryStore`,
  `SearchStore`, `RenameNetworkStore`), which arrive with the stores that
  implement them, and `uc.produce` (needs the downstream send path).
  Deviations: errors are `Store_Error` exceptions; the memory store keeps
  and returns *copies* of messages (Go shares pointers); a negative load limit
  raises (Go would panic in `make`).

- **Upstream message handling, slice 4a** (`Soja.Core.Upstream_Dispatch`,
  `Soja.Core.Downstream_Helpers`; children of `Soja.Core`): `uc.handleMessage`'s
  preamble (label, batch, prefix, server-time tag), PING, CAP (LS/ACK/NAK/NEW/
  DEL), upstream SASL PLAIN/EXTERNAL (`AUTHENTICATE`, the 900-series
  numerics), registration (001 with the autojoin of the network's saved
  channels, 004, 005 with the CASEMAPPING/CHANMODES/CHANTYPES/STATUSMSG/PREFIX
  handling and the passthrough to downstreams, end of MOTD, nick-in-use
  fallback, registration errors), and the forwarding/pending-command helpers
  and MONITOR sync those use.  The `downstreamConn` methods it calls
  (`updateSupportedCaps`, `updateNick/Host/Realname/Account`, `endSASL`,
  `setSupportedCap`) were pulled forward from the downstream step, and
  `dc.SendMessage` now does Go's full per-capability filtering.  Commands not
  handled yet (PRIVMSG/NOTICE/TAGMSG, the WHO/WHOIS/LIST/WHOX replies,
  AWAY/ACCOUNT/CHGHOST/SETNAME/INVITE, the MONITOR numerics, ...) take the
  default branch, which forwards them to the downstream connections
  unchanged, as Go's default does; 4c - 4d replace that.  `Run_Until_Registered` also sends the network's connect
  commands once registered.

  *Auto-join (user rules, 2026-10-05).*  Soja joins on its own only in the
  001 handler, once per (re)connection, from the saved channel list.  Go has
  no rejoin-after-kick or retry code, so "no rejoin after kick / ban / bad
  key" needs nothing beyond not adding any: the KICK handler (4b) must keep
  the channel in the DB but not rejoin, and the join-failure numerics are
  merely forwarded (4d).  The one new behaviour is the **channel-full
  (`ERR_CHANNELISFULL`) retry with `Soja.Backoff`**, which Go does not have
  and which lands with the numerics in 4d.

  *Bugs in soju that soja fixes (deliberate deviations; user decision
  2026-11-12):*
  - ISUPPORT negation (`-TOKEN`) never took effect in Go: `parameter` kept its
    leading `-`, so none of the `CASEMAPPING`/`CHANMODES`/`CHANTYPES`/
    `STATUSMSG`/`PREFIX` reset branches could match, and the token was deleted
    from the table under the wrong name.  Go also passed the dash-stripped
    token on to downstreams, i.e. as if the setting were being *set*.  Soja
    resets the setting, deletes the right table entry, and passes the
    original `-TOKEN` through.
  - `uc.supportsSASL(mech)` compared the mechanism with itself (the loop
    variable shadowed the parameter), so it was true whenever the server
    advertised `sasl` at all (e.g. EXTERNAL configured, server offers only
    PLAIN).  Soja matches the mechanism, case-insensitively, against the
    cap's value list (no value = everything).
  - `enqueueCommand`'s "give up after 30 s" was `copy(l, l[1:])`, which
    shifts the queue but keeps its length, duplicating the last entry; the
    following `len == 1` test then never sent the new command.  Soja drops
    the stale entry and sends the next one.
  - `handleCapAck`'s "unsupported SASL mechanism" error formatted the
    capability name instead of the mechanism.
  - `CAP LS`'s "more lines follow" test indexed `msg.Params` with
    `len(subParams)-2` (missing the offset of two), which only worked for the
    usual `CAP * LS * :caps` form.  Soja tests the sub-parameter before the
    last.
  - The memory message store's `LastMsgID` returned the *next* sequence
    number, which `LoadLatestID` then excluded as if it were the last one
    seen, so the first message stored after a `LastMsgID` call (a detach, a
    delivery receipt) was missing from the backlog.  Soja returns the newest
    message's number (0 when empty).
  - `splitWords` (BouncerServ's command line) decided that a word had ended
    by testing the previous rune for white space, which also fired for an
    escaped space: a word ending in `\ ` was lost, or glued to the next one
    (SB-09).  Soja tracks whether a word has begun.
  - `user delete` on one's own account waited for the user's own goroutine
    to stop, from that goroutine: a deadlock (SB-10).  Soja queues the stop and
    deletes the record once the user has stopped.
  - `channel update` changed the live channel field by field, so a bad value
    half-applied the change (SB-11); soja updates a copy.
  - `network delete -x` deleted the current network, reading `-x` as "no name"
    (SB-12); soja refuses it.

- **Upstream message handling, slice 4b: channel state.**  `Soja.Core.
  Upstream_Dispatch` now handles BATCH (definition, nesting, label
  inheritance), NICK, JOIN, PART, KICK, QUIT, TOPIC and the topic replies
  (331/332/333), MODE (user and channel, via `Soja.Irc.Modes`), 221, 324, 329,
  353 and 366, with `uc.produce`, `cacheUserInfo`,
  `updateChannelAutoDetach` and `parseMembershipPrefix`.  The downstream half
  they need was pulled forward into `Soja.Core.Downstream_Helpers`:
  `sendMessageWithID` / `advanceMessageWithID` (the `PING soju-msgid-<id>`
  delivery acknowledgement) with `handlePong` / `ackMsgID`, and `sendTopic` /
  `sendNames` / `forwardChannel` (the replay on 366).  As in Go, NAMES replies
  are sent with `*` as the target.
  *Auto-join rules, verified:* a KICK of our own nick drops the channel from
  the upstream's state and sends nothing upstream (tested: no line is written
  after it), and the saved channel list is untouched, so it is joined again
  only on the next connection; a PART likewise.  Joining happens only in the
  001 handler.

- **Upstream message handling, slice 4c: chat messages and detached
  channels.**  PRIVMSG / NOTICE / TAGMSG (status-message sigils stripped,
  BouncerServ's own traffic skipped, server messages, direct-message and
  `+draft/channel-context` buffers, highlight detection, push targets,
  idle-timer re-arming, echo handling through `produce`) and the detached
  channel machinery: `Soja.Core.Network_Ops` (`isHighlight`,
  `detachedMessageNeedsRelay`, `detach`, `attach`) plus, in `Downstream_
  Helpers`, `sendServiceNOTICE`/`PRIVMSG`, `relayDetachedMessage`,
  `SendBatch` and `sendTargetBacklog` (the chathistory-batch replay).
  Deviations: Web Push (`broadcastWebPush`) is not ported yet, so highlights
  and direct messages only record the push target; `isHighlight` treats an
  empty nick as "no highlight" instead of panicking; `attach` replays a
  channel only once its NAMES are complete (Go panics otherwise).

- **Kicked channels (user requirement, 2026-11-12).**  When we are kicked
  from a channel, a *kick record* is stored (who, why, when) and kept for
  good as history.  While a record is **active** (we have not rejoined) soja
  does not rejoin the channel by itself: the 001 autojoin skips it ("not
  rejoining ..."), also after the upstream reconnects and after soja itself
  restarts, and an invitation to it is shown to the clients instead of being
  accepted automatically.  Once we are back in the channel (our own JOIN
  arrives, e.g. after a client's manual JOIN) the record is marked rejoined
  and is **ignored from then on, until the next kick**; it stays in the
  table as history, and each new kick is a new record.  A kick that arrives
  while an older record is still active closes the older one (we were
  evidently back in).  Clients that connect later are told with a BouncerServ
  NOTICE per active kick (`Downstream_Helpers.Send_Kicked_Notices`, to be
  called from the welcome burst) so they can decide to rejoin.
  *Schema change (soja-specific).*  The records live in a new table,
  `KickRecord (id, network, channel, kicked_by, reason, kicked_at,
  rejoined_at)`; `rejoined_at` is NULL while the kick is active.  It is
  created with `CREATE TABLE IF NOT EXISTS` after soju's migrations and
  **without changing `PRAGMA user_version`** (still 25), so a database stays
  usable by upstream soju, which ignores the table; deleting a network or user
  deletes its kick records with it.  `Soja.Database` gained `Kick_Record`,
  `Store_Kick` and `List_Kicks`; `Core.Record_Kick` / `Clear_Kick` /
  `Load_Kicks` keep a per-network cache (`Network.Kicked`) in step with it.

- **Upstream message handling, slice 4d: replies, users, MONITOR.**  The
  WHO / WHOX / WHOIS / LIST replies (routed to the client that asked through
  the pending-command queues; WHO and WHOX replies also feed the user-info
  cache), INVITE and 341, the MONITOR numerics (730/731/734, including taking
  the desired nick when it frees up), AWAY, ACCOUNT, SETNAME, CHGHOST, the
  ban/invite/exception lists and NOSUCHNICK/NOSUCHSERVER.  `xirc/whox.go` is
  `Soja.Irc.Whox`.  Deviations: an INVITE to a saved channel that we were
  kicked from is not auto-accepted (see above); Web Push on invites is not
  ported.

- **Channel-full retries (user requirement, 2026-10-05; new in soja, soju
  has no such code).**  When a *saved* channel we are not in answers
  `ERR_CHANNELISFULL` (471), soja retries joining it with an exponential
  backoff (`Soja.Backoff`: 10 s, doubling, capped at 5 min, 5 s of jitter;
  `Join_Retry_*` in `Upstream_Dispatch`) until we are in, kicked from it, or
  it is no longer saved; a pending retry is cancelled by our own JOIN, and a
  retry that fires after the upstream connection was replaced does nothing.
  The timer posts a `Retry_Join_Event` to the user's event queue.  The other
  refusals (banned 474, bad key 475, invite-only 473, ...) are only relayed to
  the clients, never retried.  `Stop_Join_Retries` must be called when the
  upstream connection goes away (the disconnect handler, step 5).  Both timer
  actions (this and the idle detach) post to the queue without blocking for
  good, because stopping a timer waits for its action.

- **The user's event loop and network/user operations (step 5).**  `Core.Run`
  now loads the networks (and, for a persistent message store, their delivery
  receipts), then runs `Soja.Core.User_Events.Handle_Event` for each event
  until a `Stop_Event`, and finally closes the message store and sets `Done`.
  Handlers: upstream connected / disconnected / connection error / error /
  message, channel detach, downstream connected / disconnected / message,
  broadcast, user update (with a completion object the sender waits on),
  regain-nick and join-retry.  `Soja.Core.User_Ops` has `addNetwork`,
  `removeNetwork`, `checkNetwork`, `createNetwork`, `updateNetwork`,
  `deleteNetwork`, `updateUser` (as an `Update` callback on a copy of the
  record), `handleUpstreamDisconnected`, `storeClientDeliveryReceipts`,
  `bumpDownstreamInteractionTime`, the BOUNCER network attributes and state
  notifications; Go's returned `error`s are `Operation_Error` exceptions.
  Changes to what step 1-4 had:
  - the user's loop (not the network's task) sets `Network.Conn`, on
    `Upstream_Connected_Event`, as Go does;
  - `Stop_Network` closes the upstream connection, whatever phase it is in,
    and the reconnect wait is cut short when the network is stopped (Go does
    both through a context); `Network.Active_Conn` tracks the connection;
  - `connection error: ` is prefixed to the text of a failed run, as in Go;
  - `Stop_User` asks the loop to stop and waits for it (with a timeout).
  Still to come: `dc.welcome` (a client is accepted without a burst for now,
  `Downstream_Helpers.Welcome` is a stub), the registered-client command
  dispatch (every command answers 421 until step 7), and the BouncerServ
  `eventUserRun` (step 9).  Not ported: the `UpstreamUserIPs` local-address
  selection, and the filesystem store's rename on `updateNetwork`.

- **The downstream handshake and welcome (step 6).**
  `Soja.Core.Downstream_Handshake`: `handleCap` (LS with versions, LIST, REQ
  as one atomic ACK/NAK, END), `handleAuthenticate` (SASL PLAIN and ANONYMOUS,
  multi-line responses, the same limits), `handleMessageUnregistered` (NICK,
  USER, PASS, CAP, AUTHENTICATE, BOUNCER BIND, AWAY), `register`,
  `loadNetwork` (BOUNCER BIND by id, or by name, creating an unknown network
  after checking that a TLS connection to it works; `Sanity_Check` is a
  variable so tests can replace it), `welcome` (001/002/004, ISUPPORT, user
  modes, MOTD, the BOUNCER network list batch, the channel replay, the history
  backlog for the first client of a name, and the kicked-channel notices) and
  `runUntilRegistered` with its registration timeout.  `Soja.Auth` holds the
  authentication (only the "internal" bcrypt driver; "pam" and "oauth2" are
  recognised but always fail, and `main` must refuse to start with them until
  they are ported); `Core.Register_Downstream` / `Handle_Message_Unregistered`
  / `Run_Until_Registered_Downstream` are now wrappers.  `Irc_Error_Result`
  can carry a plain (non-IRC) error: the connection is dropped, as Go does for
  errors that are not `ircError`s.  Deviations / not ported: SASL OAUTHBEARER
  (needs oauth2); Web Push `VAPID=` in ISUPPORT; `CHATHISTORY=` is only sent
  for stores that support it (none yet); `welcome` no longer panics when
  called with `dc.user` already set.  A failed PASS/registration is answered
  (Go only logs it; SB-08).
  NAMES and ISUPPORT replies use `*` as their target, as in Go.

- **Ordering**: `downstream.go`, `upstream.go`, `user.go` and `service.go`
  form one mutually-dependent core (the `network` type in `user.go` holds both
  an `upstreamConn` and downstream connections), so they are ported together,
  not one file at a time.  The connection structs (`user`, `network`,
  `downstreamConn`, `upstreamConn`, `upstreamChannel`) and the event types are
  consolidated in **`Soja.Core`** (Go's single `package soju`), since Ada
  packages cannot be mutually `with`ed the way Go files share one package.
  `msgstore` (message history) and `certfp.go` are supporting, and are not
  needed for a basic connect-to-IRC build.

## Features added last (SASL EXTERNAL, OAuth 2, PAM, Web Push)

The statements above that call these features deferred or not ported are
superseded by this section.

- **`certfp generate`** (`Soja.Certgen`, `Handle_Certfp_Generate`).  The key is
  RSA (2048, 3072 or 4096 bits), ECDSA (P-384; cryptolib has no P-521) or
  Ed25519; the certificate has the TLS client profile, the common name
  `soju-auto-generated-certificate` (hyphens: cryptolib refuses blanks, and
  wants one subject alternative name, so the name is also the DNS name) and is
  valid 7300 days.  cryptolib cannot self-sign a client-profile certificate,
  so it is issued by a throwaway CA that is not kept; IRC servers check the
  fingerprint and do not look at the issuer.  Both are stored as DER, as soju
  does.  `Dial_TLS` hands AWS the certificate and key as a combined PEM in a
  0700 temporary directory, removed right after `Initialize`; AWS is not told
  to `Exchange_Certificate` (it then signs a SHA-224 token with the key, which
  fails for Ed25519).
- **A soja bug found on the way** (not soju's): SQLite read the BLOB columns
  `sasl_external_cert` and `sasl_external_key` as text, so DER was cut at its
  first NUL when the network was loaded again.  Writes now `CAST(... AS BLOB)`
  and reads use `hex()`; `tests/sqlite_check.adb` has the regression.
- **OAuth 2** (`Soja.Auth.OAuth2`, `Soja.Json`, `Soja.Url`, `Soja.Oauthbearer`).
  `auth oauth2 <url>` as in `auth/oauth2.go`: RFC 8414 discovery (10 s) and RFC
  7662 introspection, client id and secret from the URL's userinfo
  (query-escaped in the Basic header, as Go does).  JSON is read by the parser
  hbnf makes of `grammars/json.hbnf` (copied from hbnf's corpus; the three
  literals read their letters so that the tree says which was read), the URL
  by `grammars/url.hbnf` and the SASL OAUTHBEARER response by
  `grammars/oauthbearer.hbnf`.  Members are found by name in any case, a
  `null` member is absent and one of another type is an error, as
  `encoding/json` has it.  The discovery is done at startup (a failure stops
  `soja`); a reload (SIGHUP) does not repeat it.  TLS to the server is checked
  against the system CA bundle (`Soja.Tls_Default`).  OAUTHBEARER works in
  the SASL handshake and for the file upload's `Authorization: Bearer`.  A
  response that is not valid OAUTHBEARER ends the connection (go-sasl's
  error is not an IRC one, as for PLAIN).
- **PAM** (`Soja.Auth.Pam`).  libpam is loaded with `dlopen` when `soja`
  starts (it runs where PAM is not installed and then refuses `auth pam`);
  service `login`, as soju; the conversation answers the password prompt and
  gives empty answers to the others.
- **Web Push** (`Soja.Webpush`, `Soja.Core.Push`).  VAPID keys (P-256), the
  JWT (ES256), and RFC 8291 `aes128gcm` encryption with cryptolib's ECDH, HKDF
  and AES-GCM; `Encrypt` is checked against RFC 8291's example.  The
  `WEBPUSH` command, `VAPID=` in ISUPPORT, the pushes for highlights, direct
  messages, invites and read markers, and the 24 h / 30 day subscription
  rules are as in soju.  Differences: each broadcast is one task, as Go
  has one goroutine; the whole payload is one
  record (no padding); the 15 s limit is per request.

- **TLS connections are read and written one call at a time** (`Soja.Sock_Io`).
  A connection is read by one task and written by others, and OpenSSL does not
  allow `SSL_read` and `SSL_write` at once on one connection; AWS does not
  guard against it, and a `wss://` connection was now and then torn down
  (`System error (0) on SSL receive`, seen in about half the e2e runs).  Each
  socket call now holds a per-connection gate; a reader waits for input
  without holding it.  100 `wss` sessions in a row passed afterwards.  (Go's
  `crypto/tls` has its own locking, so soju has no such code.)

[soju]: https://soju.im
[ada-on-alpine]: https://github.com/moebiusV/ada-on-alpine
