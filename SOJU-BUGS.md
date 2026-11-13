# Bugs found in soju while porting it to Ada

This is the working list for the upstream pull requests: once soja is complete,
**each entry below becomes its own PR against soju** (one branch, one commit,
one Go test per bug).  Add an entry the moment a bug is found; do not batch.

- Reference revision: `upstream/soju` = `6541047` (`v0.8.0-9-g6541047`,
  2024-07-04, "readme: move to Codeberg").  Re-check every entry against
  soju's current `master` before opening its PR: some may already be fixed.
- Line numbers are in that revision.
- "Soja fix" says where the Ada port deviates from the Go code, and "Soja
  test" which test pins the fixed behaviour (a good starting point for the Go
  test in the PR).
- `PORTING.md` ("Bugs in soju that soja fixes") has the same bugs in short
  form; this file is the PR-ready version.

| ID | Where | Summary | Severity |
| --- | --- | --- | --- |
| SB-01 | `upstream.go:949` | ISUPPORT `-TOKEN` negation never takes effect, and is passed to clients as a set | medium |
| SB-02 | `upstream.go:1954` | `supportsSASL` compares the mechanism with itself | medium |
| SB-03 | `upstream.go:526` | `enqueueCommand` give-up duplicates an entry and never sends the next command | low |
| SB-04 | `upstream.go:1990` | "unsupported SASL mechanism" error prints the capability name | trivial |
| SB-05 | `upstream.go:713` | `CAP LS` continuation test indexes the wrong slice | low |
| SB-06 | `msgstore/memory.go:79` | memory store `LastMsgID` loses the next message from the backlog | medium |
| SB-07 | `downstream.go:3365` | `forwardChannel` panics on a channel whose NAMES are incomplete (reachable via `attach`) | medium |

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
