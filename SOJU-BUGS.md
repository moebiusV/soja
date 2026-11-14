# Bugs found in soju while porting it to Ada

This is the working list for the upstream pull requests: once soja is complete,
**each entry below becomes its own PR against soju** (one branch, one commit,
one Go test per bug).  Add an entry the moment a bug is found; do not batch.

- Status against current soju (re-checked 2026-11-14 against
  <https://codeberg.org/emersion/soju> `master` at `de8690c`, 221 commits
  after the translation's revision): **15 of the 19 are still present**, 3
  are fixed upstream (SB-01, SB-02, SB-08), and SB-19 is fixed apart from one
  small edge.  Ten (SB-03, 04, 05, 06, 09, 11, 13, 15, 16, 17) were
  reproduced with a failing Go test on `master` that passes with the fix; the
  other five (SB-07, 10, 12, 14, 18) were checked by reading the code.  The "Status now" column says which.
  The entries below describe the code of the old revision; where the code has
  moved, the new place is in the table.
- Reference revision: soju `6541047` (`v0.8.0-9-g6541047`, 2024-07-04,
  "readme: move to Codeberg"), from <https://git.sr.ht/~emersion/soju>
  (its last commit before the project moved to
  <https://codeberg.org/emersion/soju>, where the current `master` is; clone
  either to check an entry).  Re-check every entry against
  soju's current `master` before opening its PR: some may already be fixed.
- Line numbers are in that revision.
- "Soja fix" says where the Ada port deviates from the Go code, and "Soja
  test" which test pins the fixed behaviour (a good starting point for the Go
  test in the PR).
- `PORTING.md` ("Bugs in soju that soja fixes") has the same bugs in short
  form; this file is the PR-ready version.

| ID | Summary | In the revision soja was translated from | In soju now (`de8690c`) | Status now | Severity |
| --- | --- | --- | --- | --- | --- |
| SB-01 | ISUPPORT `-TOKEN` negation never takes effect, and is passed to clients as a set | `upstream.go:949` | `upstream.go:1046` | FIXED (1459547) | medium |
| SB-02 | `supportsSASL` compares the mechanism with itself | `upstream.go:1954` | `upstream.go:2090` | FIXED (bcd85ab) | medium |
| SB-03 | `enqueueCommand` give-up duplicates an entry and never sends the next command | `upstream.go:526` | `upstream.go:546-560` | present (restructured; `copy` still never shortens the slice) | low |
| SB-04 | "unsupported SASL mechanism" error prints the capability name | `upstream.go:1990` | `upstream.go:2127` | present | trivial |
| SB-05 | `CAP LS` continuation test indexes the wrong slice | `upstream.go:713` | `upstream.go:823` | present | low |
| SB-06 | memory store `LastMsgID` loses the next message from the backlog | `msgstore/memory.go:79` | `msgstore/memory.go:79` | present | medium |
| SB-07 | `forwardChannel` panics on a channel whose NAMES are incomplete (reachable via `attach`) | `downstream.go:3365` | `user.go:428, downstream.go:4124` | present | medium |
| SB-08 | a failed authentication is never reported to the client | `downstream.go:1710` | `downstream.go:1972` | FIXED (bd9873e; the error is sent and the connection closed, no retry) | medium |
| SB-09 | `splitWords` loses or glues a word that ends in an escaped space | `service.go:74` | `service.go:77-118` | present | low |
| SB-10 | `user delete <own name>` waits for the user's own goroutine and never returns | `service.go:1157` | `service.go:1238` | present | high |
| SB-11 | `channel update` with a bad value half-applies the change in memory | `service.go:1408` | `service.go:1415-1445` | present | low |
| SB-12 | `network delete -x` deletes the current network | `service.go:677` | `service.go:744, 520, 1076` | present (`-x` is taken as "no name") | low |
| SB-17 | renaming a network that has no logs yet logs an error | `msgstore/fs.go:557` | `msgstore/fs.go:551` | present | low |
| SB-18 | the file store keeps the user's nick from when it was created | `user.go:539` | `user.go:599` | present | low |
| SB-19 | a failed upload leaves the partly written file; an upload with no name is stored as `<token>-.ext` | `fileupload/fs.go:77` | `fileupload/fs.go` | FIXED (3dec1ed); one edge left: `path.Base("")` is "." when Content-Disposition has no filename | low |
| SB-15 | `CHATHISTORY TARGETS` lists a target that has only events, with the zero time | `database/sqlite.go:1130` | `database/sqlite.go:1192` | present (SQLite only; Postgres drops these targets) | low |
| SB-16 | `SEARCH` fails when its text has no word in it | `database/sqlite.go:1242` | `database/sqlite.go:1270, 1333` | present (SQLite only) | low |
| SB-14 | the inactive-user loop re-disables disabled users, says "deleted", and stops at the first failure | `server.go:725` | `server.go:759, 810; database/sqlite.go:240` | present (all three parts) | low |
| SB-13 | `BOUNCER ADDNETWORK`/`CHANGENETWORK` build an unusable address from an IPv6 host | `downstream.go:140` | `downstream.go:151` | present | low |

---

## SB-01: ISUPPORT negation (`-TOKEN`) never takes effect

`upstream.go:949`.  In the `RPL_ISUPPORT` handler:

```go
parameter := token
var negate, hasValue bool
var value string
if strings.HasPrefix(token, "-") {
	negate = true
	token = token[1:]          // only `token` loses the dash
} else if i := strings.IndexByte(token, '='); i >= 0 {
	...
}
parameter = strings.ToUpper(parameter)   // still "-PREFIX"
```

**Effect.**  `parameter` keeps its leading `-`, so (a) `delete(uc.isupport, ...)`
deletes the wrong key, and (b) none of the `case "CASEMAPPING"` / `"CHANMODES"` /
`"CHANTYPES"` / `"STATUSMSG"` / `"PREFIX"` negation branches can ever run, so
`-PREFIX` leaves the old memberships in place.  Also, the passthrough
(`downstreamIsupport = append(downstreamIsupport, token)`) uses the
dash-stripped `token`, so a negation reaches downstream clients as if the
setting were being *set* (`PREFIX` with no value instead of `-PREFIX`).

**Suggested patch.**

```diff
-			parameter := token
+			rawToken := token
+			parameter := token
 			var negate, hasValue bool
 			var value string
 			if strings.HasPrefix(token, "-") {
 				negate = true
-				token = token[1:]
+				parameter = token[1:]
 			} else if i := strings.IndexByte(token, '='); i >= 0 {
 ...
 			if passthroughIsupport[parameter] {
-				downstreamIsupport = append(downstreamIsupport, token)
+				downstreamIsupport = append(downstreamIsupport, rawToken)
 			}
```

**Soja fix.**  `Handle_Isupport` in `src/soja-core-upstream_dispatch.adb`.
**Soja test.**  `tests/upstream_dispatch_check.adb`: `-PREFIX -CHANTYPES
-STATUSMSG` and `-CHANMODES` sections.

## SB-02: `supportsSASL` compares the mechanism with itself

`upstream.go:1942` (`1954`):

```go
mechanisms := strings.Split(v, ",")
for _, mech := range mechanisms {          // shadows the parameter `mech`
	if strings.EqualFold(mech, mech) {     // always true
		return true
	}
}
```

**Effect.**  Whenever the server advertises `sasl` at all (with any value
list), `supportsSASL(anything)` is true.  A network configured for EXTERNAL
against a server that only offers PLAIN still starts SASL (`requestSASL`), the
server rejects the mechanism, and registration is delayed/fails;
`updateSupportedCaps` also tells clients `sasl=PLAIN,ANONYMOUS` when the
upstream only offers, say, SCRAM.

**Suggested patch.**

```diff
-	for _, mech := range mechanisms {
-		if strings.EqualFold(mech, mech) {
+	for _, m := range mechanisms {
+		if strings.EqualFold(m, mech) {
 			return true
```

**Soja fix.**  `Supports_SASL`.  **Soja test.**  `upstream_dispatch_check`:
"mechanisms are matched case-insensitively" / "a mechanism the server does
not list is not supported".

## SB-03: `enqueueCommand`'s "give up" duplicates an entry

`upstream.go:510` (`526`):

```go
if t := uc.pendingCmds[msg.Command][0].sentAt; !t.IsZero() && time.Since(t) > 30*time.Second {
	copy(uc.pendingCmds[msg.Command], uc.pendingCmds[msg.Command][1:])
}

if len(uc.pendingCmds[msg.Command]) == 1 {
	uc.sendNextPendingCommand(msg.Command)
}
```

**Effect.**  `copy` shifts the entries down but does not shorten the slice, so
the last entry ends up twice in the queue (`[stale, new]` becomes `[new, new]`),
and the following `len == 1` test is false, so the new command is never sent:
the asking client waits forever.  Longer queues have the same problem for the
entries after the stale one.

**Suggested patch.**

```diff
 	if t := uc.pendingCmds[msg.Command][0].sentAt; !t.IsZero() && time.Since(t) > 30*time.Second {
-		copy(uc.pendingCmds[msg.Command], uc.pendingCmds[msg.Command][1:])
+		// Give up on the stale command and send the next one.
+		uc.pendingCmds[msg.Command] = uc.pendingCmds[msg.Command][1:]
+		uc.sendNextPendingCommand(msg.Command)
+		return
 	}
```

**Soja fix.**  `Enqueue_Command`.  **Soja test.**  `upstream_dispatch_check`:
"the next command is sent after giving up" / "the stale command is dropped,
not duplicated".

## SB-04: "unsupported SASL mechanism" names the capability

`upstream.go:1990`, in `handleCapAck(ctx, name string, ok bool)`:

```go
default:
	return fmt.Errorf("unsupported SASL mechanism %q", name)
```

`name` is the capability (`"sasl"`), not the mechanism, so the message is always
`unsupported SASL mechanism "sasl"`.  **Patch:** use `auth.Mechanism`.
**Soja fix.**  `Handle_Cap_Ack`.  **Soja test.**  `upstream_dispatch_check`:
"unsupported mechanism".

## SB-05: `CAP LS` continuation test indexes the wrong slice

`upstream.go:713`:

```go
subParams := msg.Params[2:]
...
more := len(subParams) >= 2 && msg.Params[len(subParams)-2] == "*"
```

The index is computed for `subParams` but applied to `msg.Params`, which is two
longer.  It only works for the usual `CAP * LS * :caps` (2 sub-parameters,
index 0, which happens to be the `*` target).  With any other shape the
continuation marker is missed or a wrong parameter is tested.
**Patch:** `subParams[len(subParams)-2]`.  **Soja fix.**  `Handle_Cap`.
**Soja test.**  `upstream_dispatch_check`: "CAP LS continuation with extra
parameters".

## SB-06: memory store `LastMsgID` loses the next message from the backlog

`msgstore/memory.go:79`:

```go
func (ms *memoryMessageStore) LastMsgID(...) (string, error) {
	var seq uint64
	if rb, ok := ms.buffers[k]; ok {
		seq = rb.cur          // the NEXT sequence number to be assigned
	}
	return formatMemoryMsgID(network.ID, entity, seq), nil
}
```

`Append` assigns `seq := rb.cur` and then increments it, so `cur` is the number
of the *next* message.  `LoadLatestSeq(seq, ...)` returns the messages *after*
`seq` (it computes `diff := rb.cur - seq - 1`), and treats `seq == cur` as
"nothing yet" and `seq > cur` as an error: `seq` is meant to be the last
message already seen.

**Effect.**  After `LastMsgID`, the first message appended is excluded from
`LoadLatestID(id)`.  This is the ID taken when a channel is detached
(`network.detach`) and the one stored in delivery receipts, so the first
message received while detached (or while a client is away) is missing from the
backlog replayed on reattach/reconnect.  (An entity with no buffer yet returns
`seq = 0`, which is right; only an existing buffer is off by one.)

**Suggested patch.**

```diff
 	if rb, ok := ms.buffers[k]; ok {
-		seq = rb.cur
+		seq = rb.cur - 1
 	}
```

(`cur` starts at 1, so an empty buffer also gives 0, matching the no-buffer
case.)

**Soja fix.**  `Last_Msg_ID` in `src/soja-msgstore-memory.adb`.
**Soja test.**  `tests/msgstore_check.adb`: "the first message after a last
id is not lost"; `upstream_dispatch_check`: the detach/attach backlog replay.

## SB-07: `forwardChannel` panics on an incomplete channel

`downstream.go:3365`:

```go
func forwardChannel(ctx context.Context, dc *downstreamConn, ch *upstreamChannel) {
	if !ch.complete {
		panic("Tried to forward a partial channel")
	}
```

`network.attach` (`user.go:374`) calls it for every attached downstream
whenever the upstream channel exists:

```go
if uch != nil {
	forwardChannel(ctx, dc, uch)
}
```

**Effect.**  A message in a *detached* channel can reattach it
(`handleDetachedMessage`, `ReattachOn` message/highlight).  If that message
arrives after our JOIN but before `RPL_ENDOFNAMES` (for example right after
reconnecting), `uch.complete` is false and the whole bouncer process panics.

**Suggested patch.**  Replay only complete channels in `attach` (the channel is
forwarded when its NAMES end anyway, `RPL_ENDOFNAMES`):

```diff
-		if uch != nil {
+		if uch != nil && uch.complete {
 			forwardChannel(ctx, dc, uch)
 		}
```

**Soja fix.**  `Attach` in `src/soja-core-network_ops.adb` (replays only when
`Uch.Complete`).  **Soja test.**  `upstream_dispatch_check` (reattach on
highlight with an incomplete channel).

## SB-08: a failed authentication is never reported to the client

`downstream.go:1710`, in `runUntilRegistered`:

```go
err = dc.handleMessage(ctx, msg)
if ircErr, ok := err.(ircError); ok {
	ircErr.Message.Prefix = dc.srv.prefix()
	dc.SendMessage(ctx, ircErr.Message)       // errors of handleMessage are sent ...
} else if err != nil {
	return fmt.Errorf("failed to handle IRC command %q: %v", msg, err)
}

if dc.registration.nick != "" && dc.registration.username != "" && !dc.registration.negotiatingCaps {
	return dc.register(ctx)                    // ... but those of register are not
}
```

`dc.register` returns `ircError`s (`ERR_PASSWDMISMATCH "Authentication
failed"`, `FAIL * ACCOUNT_REQUIRED`, the client/network name mismatches).  They
are returned as an `error` to `Server.Handle` (`server.go:485`), which only logs
them and returns, so the deferred `dc.Shutdown` closes the connection **without
the client ever receiving the reply**.  A client with a wrong password just sees
the connection drop.  (`register` clears `dc.registration.pass` first, which
suggests the client was meant to be able to try again after the error.)  Looks
like a regression from when `register` stopped being called from
`handleMessage`; check against current `master` first.

**Suggested patch.**

```diff
 		if dc.registration.nick != "" && dc.registration.username != "" && !dc.registration.negotiatingCaps {
-			return dc.register(ctx)
+			err := dc.register(ctx)
+			if ircErr, ok := err.(ircError); ok {
+				ircErr.Message.Prefix = dc.srv.prefix()
+				dc.SendMessage(ctx, ircErr.Message)
+			} else if err != nil {
+				return err
+			}
 		}
```

(Then the loop continues and the client may retry, as before.  Returning the
error instead after sending it would close the connection right after the
reply.)

**Soja fix.**  `Run_Until_Registered` in
`src/soja-core-downstream_handshake.adb` sends the reply and lets the client
retry.  **Soja test.**  `tests/handshake_check.adb`: "a wrong password is
reported", "authentication required", "ACCOUNT_REQUIRED", "mismatch is
reported".

---

## Possible, not yet confirmed

- `user.go` `updateNetwork` builds the replacement network with `newNetwork`,
  whose `delivered` store is empty, while delivery receipts are only loaded
  from the database in `user.run` at startup.  With a persistent message store,
  after a network update the in-memory receipts are gone; when a client then
  disconnects, `storeClientDeliveryReceipts` rewrites that client's rows from
  the (now nearly empty) map, which looks like it drops its older receipts, so
  the backlog for those targets would no longer be replayed.  Needs a test
  against a real persistent (fs/db) store to confirm; soja copies Go's
  behaviour for now (and the memory store is not persistent, so it is not
  affected).

- `irc.go:265`: `isHighlight` panics on an empty nick.  Not reachable in
  normal operation (the nick is never empty once configured); soja returns
  "not a highlight" instead.  Probably not worth a PR on its own.

## SB-09: `splitWords` loses or glues a word that ends in an escaped space

`service.go:74`.  `splitWords` decides that a word has ended by looking at the
previous *rune*:

```go
} else if wordDelim == ' ' && unicode.IsSpace(r) {
	// end of last word
	if !unicode.IsSpace(prev) {
		words = append(words, lastWord.String())
		lastWord.Reset()
	}
}
...
prev = r                      // set for escaped runes too
```

and, at the end, `if !unicode.IsSpace(prev) { words = append(...) }`.

**Effect.**  `prev` is also set for a rune that was escaped with a backslash,
so an escaped space counts as white space:

- `network create -addr x -name my\ ` (an escaped space last): the last word
  is dropped.
- `a\  b` (escaped space, then a real one): the real space does not end the
  word, so the command sees one word `a b` instead of `a ` and `b`.

Escaped spaces in the middle of a word (`my\ net`) work, which is why it goes
unnoticed.

**Suggested patch.**  Track "a word has begun" instead of inspecting `prev`:

```diff
-	prev := ' '
+	inWord := false
 ...
 		if escape {
 			lastWord.WriteRune(r)
+			inWord = true
 			escape = false
 		} else if r == '\\' {
 			escape = true
+			inWord = true
 		} else if wordDelim == ' ' && unicode.IsSpace(r) {
-			if !unicode.IsSpace(prev) {
+			if inWord {
 				words = append(words, lastWord.String())
 				lastWord.Reset()
+				inWord = false
 			}
 ...
 		} else {
 			lastWord.WriteRune(r)
+			inWord = true
 		}
-
-		prev = r
 	}
-	if !unicode.IsSpace(prev) {
+	if inWord {
```

(The quote branches need `inWord = true` where a quote opens, so that `""` is
still an empty word.)  Soja's `Soja.Service_Words.Split_Words` does this.

## SB-10: `user delete` on one's own account deadlocks the user

`service.go:1157`, in `handleUserDelete`:

```go
self := ctx.user != nil && ctx.user.Username == username
...
if err := u.stop(deleteCtx); err != nil {   // deleteCtx = context.TODO() when self
```

and `user.stop` (`user.go:1218`) sends `eventStop{}` to `u.events` and then
waits for `u.done`.

**Effect.**  A command sent to BouncerServ by a client runs on the **user's own
goroutine** (`handleMessageRegistered` is called from the event loop).  When the
target is the user itself, `stop` waits for the goroutine that is waiting: the
event loop never gets to the `eventStop`, `u.done` is never closed, and the
context is `context.TODO()` (never cancelled, as the comment about the closing
connection explains).  The user's loop hangs for good: none of that user's
clients or upstream networks are served any more, and the account is not
deleted.  The same happens for an admin's `user run <name> user delete <name>
<token>`, which runs the command on `<name>`'s goroutine.  Deleting *another*
user works, since that runs on the caller's goroutine.

**Suggested patch.**  When `self` (or `ctx.user == u`), do not wait: record that
the account is to be deleted, queue the stop, and delete the row once `run` has
returned (after the networks were stopped and the delivery receipts stored):

```diff
-	if err := u.stop(deleteCtx); err != nil {
-		return fmt.Errorf("failed to stop user: %v", err)
-	}
-
-	if err := ctx.srv.db.DeleteUser(deleteCtx, u.ID); err != nil {
+	if self {
+		u.deleteOnStop = true
+		select {
+		case u.events <- eventStop{}:
+		default:
+			return fmt.Errorf("failed to stop user: event queue is full")
+		}
+		return nil
+	}
+
+	if err := u.stop(deleteCtx); err != nil {
+		return fmt.Errorf("failed to stop user: %v", err)
+	}
+	if err := ctx.srv.db.DeleteUser(deleteCtx, u.ID); err != nil {
```

(with `if u.deleteOnStop { srv.db.DeleteUser(...) }` after the loop in
`user.run`).  Check against current `master` first.

## SB-11: `channel update` half-applies a change that is then refused

`service.go:1408`.  `channelFlagSet.update(ch)` writes each option into the live
`*database.Channel` as it goes, and returns on the first bad one:

```go
if fs.RelayDetached != nil { ...; channel.RelayDetached = filter }
if fs.ReattachOn != nil   { ...; channel.ReattachOn = filter }
if fs.DetachAfter != nil  { dur, err := ...; if err != nil || dur < 0 { return fmt.Errorf(...) }; ... }
```

**Effect.**  `channel update #c -relay-detached none -detach-after bogus` fails
with an error, but `RelayDetached` of the in-memory channel is already `none`
(the database is not written).  The bouncer then behaves differently from what
is stored until the next restart, and from what the user was told.

**Suggested patch.**  Update a copy and assign it only when everything parsed:

```diff
-	if err := fs.update(ch); err != nil {
+	updated := *ch
+	if err := fs.update(&updated); err != nil {
 		return err
 	}
+	*ch = updated
```

## SB-12: `network delete -x` deletes the current network

`service.go:677`, `handleServiceNetworkDelete` (via `getNetworkFromArg`):

```go
name, params := popArg(params)     // a word starting with "-" is not a name
if name == "" {
	if ctx.network == nil { return ..., fmt.Errorf("no network selected, a name argument is required") }
	return ctx.network, params, nil
}
```

**Effect.**  `network delete` checks that it got exactly one parameter, but
`popArg` treats a parameter that starts with `-` (`-x`, `-network`, a typo of a
flag) as "no name given", so the network the client is connected to is deleted,
without confirmation.

**Suggested patch.**  After the parameter count check:

```diff
 	if len(params) != 1 {
 		return fmt.Errorf("expected exactly one argument")
 	}
+	if strings.HasPrefix(params[0], "-") {
+		return fmt.Errorf("unexpected argument: %v", params[0])
+	}
```

## SB-13: an IPv6 host from `bouncer-networks` attributes gives an unusable address

`downstream.go:140`, `networkAddrFromAttrs`:

```go
addr := host
if port := string(attrs["port"]); port != "" {
	addr += ":" + port
}
```

**Effect.**  `fillNetworkAddrAttrs` reports an IPv6 network as `host=::1`
(brackets stripped by `net.SplitHostPort`), so a client that edits a network
and sends `host=::1;port=6667` back makes the address `::1:6667`.  That does
not parse as host and port, and the network can no longer connect.  Clients
that round-trip the attributes of an IPv6 network hit this.

**Suggested patch.**  Use `net.JoinHostPort` when there is a port, and bracket
a bare IPv6 host:

```diff
-	addr := host
-	if port := string(attrs["port"]); port != "" {
-		addr += ":" + port
-	}
+	addr := host
+	if port := string(attrs["port"]); port != "" {
+		addr = net.JoinHostPort(host, port)
+	} else if strings.Contains(host, ":") {
+		addr = "[" + host + "]"
+	}
```

## SB-14: `disableInactiveUsers` re-disables, mislabels and gives up early

`server.go:725`.  Three things in the same function:

```go
usernames, err := s.db.ListInactiveUsernames(ctx, time.Now().Add(-delay))
...
for _, username := range usernames {
	u := s.users[username]
	...
	if n := u.numDownstreamConns.Load(); n > 0 { continue }
	users = append(users, u)
}
...
for _, u := range users {
	...
	case err := <-done:
		if err != nil {
			return err
		} else {
			s.Logger.Printf("deleted inactive user %q", u.Username)
		}
```

**Effect.**

1. `ListInactiveUsernames` selects `coalesce(downstream_interacted_at,
   created_at) < ?` without looking at `enabled`.  A user that was disabled
   for inactivity stays "inactive" for ever (nothing bumps the time), so every
   four hours it is sent another `eventUserUpdate{enabled: false}`, which
   stores the record again and logs again.
2. The log line says `deleted inactive user`, but the user is only disabled.
3. `return err` on the first failing user means the users after it in the list
   are not disabled in that round (and not until the failing one is fixed,
   since it is first in line every time).

**Suggested patch.**  Skip users that are already disabled (`!u.Enabled`, or
`AND enabled` in the query), say "disabled inactive user", and log and continue
on a per-user error instead of returning.

## SB-15: targets with only events are listed, with the zero time

`database/sqlite.go:1130`, `ListMessageLastPerTarget`:

```go
innerQuery := `SELECT time FROM Message WHERE target = MessageTarget.id `
if !options.Events { innerQuery += `AND text IS NOT NULL ` }
innerQuery += `ORDER BY time DESC LIMIT 1`
query := `SELECT target, (` + innerQuery + `) latest FROM MessageTarget WHERE network = :network `
```

**Effect.**  A target whose messages are all events (a channel with only JOIN or
PART lines stored) has no `PRIVMSG`/`NOTICE`, so `latest` is `NULL`.  Without
bounds nothing filters it out, and with `ORDER BY latest ASC` NULL sorts first:
`CHATHISTORY TARGETS` (from a client without `draft/event-playback`) lists the
target as the very oldest, with the zero time `0001-01-01T00:00:00.000Z`.  With
a bound (`latest > :after`) it disappears, so the answer also depends on
whether the client sent a bound.

**Suggested patch.**  `query += "AND latest IS NOT NULL "` after the `network`
condition.

## SB-16: `SEARCH` fails when the text contains no word

`database/sqlite.go:1242` with `quoteFTSQuery` (`:1301`):

```go
if options.Text != "" {
	query += `AND m.id IN (SELECT ROWID FROM MessageFTS WHERE MessageFTS MATCH :text) `
}
... sql.Named("text", quoteFTSQuery(options.Text)),
```

`quoteFTSQuery` splits on everything that is not a letter, number or private-use
character, and quotes each token; text made only of separators (`!!!`, `?`,
`:)`) has no token, so it returns `""`.

**Effect.**  `MATCH ''` is a syntax error in FTS5 (`fts5: syntax error near ""`),
so `SEARCH text=!!!;in=#chan` is answered `FAIL SEARCH INTERNAL_ERROR Messages
could not be retrieved` (and logged as a failure) instead of an empty result.

**Suggested patch.**  Text with no word cannot match anything: return an empty
list when `quoteFTSQuery` gives `""`.

## SB-17: renaming a network without logs is reported as a failure

`msgstore/fs.go:557`, `RenameNetwork`, called from `updateNetwork`
(`user.go:1099`) whenever the network's name changes:

```go
oldDir := filepath.Join(ms.root, EscapeFilename(oldNet.GetName()))
newDir := ...
if _, err := os.Stat(newDir); err == nil { return fmt.Errorf("destination %q already exists", newDir) }
return os.Rename(oldDir, newDir)
```

**Effect.**  The network directory is created by the first message that is
logged.  A network that has not logged anything yet (just created, never
connected, or no traffic) has no directory, so `os.Rename` fails with "no such
file or directory", and `updateNetwork` logs `failed to update message store
network name to "...": rename ...: no such file or directory`.  Nothing is
wrong, there was nothing to move; the log line is noise, and it hides real
failures.

**Suggested patch.**  `if _, err := os.Stat(oldDir); os.IsNotExist(err) { return nil }`
before the rename.

## SB-18: the file store keeps the nick the user had when it was created

`user.go:539`:

```go
msgStore = msgstore.NewFSStore(srv.Config().MsgStorePath, record)
...
return &user{ User: *record, ... }
```

`newUser` copies the record into `u.User`; the store keeps the pointer to the
original `record`.  `updateUser` (`user update -nick`, a changed realname,
...) changes `u.User` only, so the store never sees it.

**Effect.**  The store uses the user's nick to rewrite the entity of a private
message *to us* when it reads it back (`znclog.UnmarshalLine`: the logs do not
hold our own nick).  After the user changes their default nick, replayed
private messages are addressed to the old nick until the bouncer restarts.

**Suggested patch.**  Give the store the live record (`&u.User`) or tell it on
update, as `eventUserUpdate` is handled.

## SB-19: file upload keeps a failed upload, and names an unnamed one "<token>-.ext"

`fileupload/fs.go`, `store`:

```go
origBasename = filepath.Base(origBasename)       // "" becomes "."
...
f, err = os.OpenFile(..., os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
...
if _, err := io.Copy(f, r); err != nil {         // f stays on disk
    return "", fmt.Errorf("failed to write file: %v", err)
}
```

**Effect.**  (1) The handler answers 500 when the body is too large or the
connection breaks, but the file it had written so far stays in the user's
directory, for ever: a way to fill the disk with 50 MiB pieces that no address
points to.  (2) `filepath.Base("")` is `"."`, so an upload without a
Content-Disposition filename is stored as `<token>-.<ext>`, which is then shown
as `.<ext>`.

**Suggested patch.**  Remove the file when the copy fails (`os.Remove(f.Name())`),
and take the base only when the name is not empty.

soja removes the partial file and keeps an empty name empty (`<token>.<ext>`).

