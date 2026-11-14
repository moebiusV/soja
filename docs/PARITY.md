# Parity with soju

[← README](../README.md)

soja was translated from soju `6541047` (2024-07-04). soju has moved to
<https://codeberg.org/emersion/soju> and its `master` (`de8690c`, 2026-11-12) is
221 commits further on. soja is to be at parity with that `master` before it is
released as 1.0.0. This page is the list of what that takes, from a comparison
of the two source trees (2026-11-14), and what has been done. **Done** means
implemented in soja with a test; the upstream commit is given so that the
change can be read.

## 1. Data and start-up: soja must open soju's database and configuration

| | Item | Upstream | Status |
|---|---|---|---|
| [x] | SQLite schema version 31: `User.max_networks`; `MessageTarget` `pinned`, `muted`, `blocked`; foreign-key indexes; `DeviceCertificate`; fresh schema and migrations 25-30 | `a30cda7` `c13c50c` `527ad97` `64fdd53` `838da54` `b978255` | done |
| [x] | WAL and `synchronous = NORMAL` | `36cd653` | done |
| [ ] | foreign keys on (`PRAGMA foreign_keys`), with the delete order audited | `2a7a469` | open |
| [ ] | `DeleteUser` removes the user's device certificates | | open |
| [x] | default `message-store` is `db` | `4040927` | done |
| [x] | drivers that take no source refuse one (`message-store db x`, `auth internal x`) | `6d79a8f` | done |
| [ ] | several `auth` lines; `auth http <url>` | `f13b47e` `04fdb35` | open |
| [ ] | `icon`, `accept-proxy-unix`, `message-expiry`, `client-cert-auth` directives | `89ce2f1` `ff99b6a` `2155529` `19e86d2` | open |
| [ ] | `file-upload http <url>` | `c4dcf1d` | open |
| [ ] | `listen` schemes `irc://`, `ws://`, `http://` (localhost), `http+insecure+prometheus://`, `irc+unix://host/path` | `ec9be26` `645c696` `a7e2be3` | open |
| [x] | PAM service name is `soju` (the `pam.d` file is the administrator's) | `fa03c22` | done |

## 2. Protocol and core

| | Item | Upstream | Status |
|---|---|---|---|
| [x] | `JOIN` errors carry the client's nick | `c2b151f` | done |
| [x] | self `WHO` reports away (`G`) | `a3716dc` | done |
| [x] | `CHATHISTORY` on a bouncer connection is `FAIL ... INVALID_TARGET` | `44791ce` | done |
| [x] | `STATUSMSG` sigils are removed before logging and NickServ detection | `ab36141` | done |
| [x] | welcome-time `JOIN`s carry account and real name (extended-join) | `a2a4181` | done |
| [x] | all timed-out pending commands are dropped | `29c0824` | done |
| [x] | `network update` keeps delivery receipts, push targets, last error, case-mapping | `f48eb92` `b4df87f` | done |
| [x] | the admin socket refuses `CAP`, `NICK`, `USER`, `PASS` | `a25b692` | done |
| [x] | `no-implicit-names` capability (unprefixed) | `c333c3b` | done |
| [ ] | `CHATHISTORY AROUND` | `dd09fc4` | open |
| [ ] | Web Push: https endpoints only, no private addresses, VAPID subscriber `https://soju.im`; deferred, muted and blocked rules | `0b76d2d` `a5d11bd` `a29c036` `2d02be7` `d9aebc8` `8c3ef5b` | open |
| [ ] | NickServ `SET` only saves `SET PASSWORD` | `de8690c` | open |
| [ ] | connect commands after registration, 3 s before joining | `cef94ff` `5e89246` `0fee055` | open |
| [ ] | `draft/extended-isupport` and the `ISUPPORT` command; tokens sorted; `soju.im/SAFERATE`, `draft/ACCOUNTREQUIRED`, `ACCOUNTEXTBAN`, `draft/ICON`, `LINELEN` | `6d22e65` `1459547` `6e4fb18` `8bff925` | open |
| [ ] | SASL PLAIN impersonation by administrators | `7c24ded` `4764802` | open |
| [ ] | `labeled-response` for clients | `70c4ded` | open (large) |
| [ ] | `draft/message-redaction` and `REDACT` | `34affa3` | open |
| [ ] | `METADATA` / `draft/metadata-2`: pinned, muted, blocked targets | `6f9d7cb` `a30cda7` `527ad97` | open (large) |
| [ ] | device certificates: client certificates over TLS and PROXY, SASL EXTERNAL for clients, `CLIENTCERT`, `soju.im/client-cert` | `838da54` `8fadc57` `190ac40` | open (large) |
| [ ] | `echo-message` requested upstream whenever offered | `66e0f9a` | open |

## 3. BouncerServ and stores

| | Item | Upstream | Status |
|---|---|---|---|
| [x] | `user create/update -max-networks`, `network -ignore-limit`, limit counts enabled networks, `user status` text | `c13c50c` `8e6a353` | done |
| [x] | `channel create`; `server debug` | `8c2bc64` `9bc8f67` | done |
| [x] | help texts: `-h` answer, fixed choices without angle brackets, `irc+unix` only, "reserved" wording | `1e8c492` `b62df53` `69d529e` | done |
| [x] | non-administrators cannot add `unix://` networks | `e75b8c7` | done |
| [ ] | `message-expiry` for the db and fs stores | `2155529` | open |
| [ ] | search text without formatting codes (`stripANSI`) | `2489318` | open |
| [x] | file upload: PDF inline, `media-src 'self'`, 413 with `Upload-Limit`, username cut at `/` or `@` | `aadecee` `3ef9cb8` `c1116b5` | done |
| [ ] | Forwarded headers on `auth` requests | `d343f4b` `a1631a2` | open |

## 4. soju bugs still present

The 15 bugs in [SOJU-BUGS.md](../SOJU-BUGS.md) that soju has not fixed are
fixed in soja (soja does not reproduce them), so nothing here is open for soja
itself.

See also: [differences.md](differences.md), [PORTING.md](../PORTING.md).
