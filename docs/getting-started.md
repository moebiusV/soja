# Getting started

soja is a drop-in replacement for [soju], the IRC bouncer. If you know soju you
already know soja: same configuration file, same database, same BouncerServ
commands. The differences are listed in [differences.md](differences.md). The
programs are `soja` (the bouncer), `sojadb` (create users) and `sojactl` (send
commands to a running bouncer); see their man pages in this directory
(`soja.1`, `sojadb.1`, `sojactl.1`, in mdoc format: `man -l docs/soja.1`).

## Server side

Build soja (see the [README](../README.md)) or install the `soja` package from
[ada-on-alpine]. Then create the administrator and a configuration file:

    sojadb create-user <username> -admin

`sojadb` asks for the password. A minimal `/etc/soju/config` that listens with
TLS on the default IRC-over-TLS port, keeps its messages in the database, and
has the admin socket that `sojactl` uses:

    listen ircs://
    listen unix+admin://
    tls /etc/soju/cert.pem /etc/soju/key.pem
    hostname bouncer.example.org
    message-store db

(`/etc/soju/config` and `./soju.db` are soju's default paths, kept so that an
existing soju installation can switch to soja by changing the program. For a
quick local try, leave TLS out and use
`soja -listen irc+insecure://127.0.0.1:6667`, which is plain text and for
localhost only.)

Start it:

    soja

`soja` reloads the certificate and the configuration on `SIGHUP`, as soju does.
If you already run soju, point soja at the same configuration and database and
stop soju first; do not run both against one database.

## Client side

Connect any IRC client to the bouncer with your bouncer username and password.

- A client that supports the `soju.im/bouncer-networks` extension (see soju's
  client list) shows and manages your networks itself.
- Any other client needs one server entry per network, with the network in the
  username: `<username>/<network>`. If the name is a host name and the network
  does not exist yet, soja adds it. For Libera Chat the username is
  `<username>/irc.libera.chat`. To connect from several clients, add a client
  name: `<username>/irc.libera.chat@laptop`.
- Everything else is done by talking to `BouncerServ`: `/msg BouncerServ help`.

## Example: OFTC, with your nick and a certificate

This sets up a network on [OFTC], registers a nick, and has the bouncer log in
with a client certificate (CertFP), so that it identifies by itself every time
it connects. The steps for the certificate follow OFTC's own page for soju,
<https://www.oftc.net/NickServ/CertFP/>, which describes this exact sequence.

> Not yet run against OFTC itself: soja's certificate generation and SASL
> EXTERNAL are tested against a local TLS server that demands the certificate,
> and the OFTC commands below are from OFTC's documentation. If something
> here is different on the live network, OFTC's page is right and this one
> needs fixing.

Send these in your client, to `BouncerServ` unless it says otherwise. Use your
own nick, password and e-mail address.

1. **Add the network.**

       /msg BouncerServ network create -addr ircs://irc.oftc.net -name oftc -nick yournick

   Wait until `/msg BouncerServ network status` shows it connected.

2. **Register the nick** (skip this if the nick already has an account):

       /msg NickServ REGISTER yourpassword you@example.org

   OFTC answers with a link to a page where you must solve a CAPTCHA to verify
   the account; it expires after an hour (`/msg NickServ REVERIFY` asks for a
   new one). soja notices a registration to NickServ and keeps the password to
   identify with next time.

3. **Make the certificate** and reconnect with it:

       /msg BouncerServ certfp generate -network oftc
       /msg BouncerServ network update oftc

   The certificate and key are stored in soja's database, with the network.
   The reconnect presents the certificate to OFTC. OFTC does not know it yet,
   so the SASL login by certificate fails for now; that is expected, soja logs
   it and carries on.

4. **Identify and add the certificate to the nick.** Use `network quote`, which
   sends a line straight to OFTC. (Identifying with a plain `/msg NickServ
   IDENTIFY` would make soja store your password and switch the network back to
   logging in by password, undoing step 3.)

       /msg BouncerServ network quote oftc "PRIVMSG NickServ :IDENTIFY yourpassword"
       /msg BouncerServ network quote oftc "PRIVMSG NickServ :CERT ADD"

   NickServ replies with a line like `CERT list entry <fingerprint> added`.
   `CERT ADD` records the certificate of the connection you are on; OFTC uses
   a SHA-1 fingerprint, which `/msg BouncerServ certfp fingerprint -network
   oftc` also shows.

5. **Reconnect, and check:**

       /msg BouncerServ network update oftc
       /msg BouncerServ sasl status -network oftc

   From now on the bouncer logs in as your nick by certificate every time it
   connects, and your password is not stored anywhere on the bouncer for this
   network.

To go back to a password login, `sasl set-plain <nick> <password>` or
`sasl reset`; see `soja(1)`.

## Where to read more

- `soja(1)`: every configuration directive and every BouncerServ command.
- [differences.md](differences.md): what soja does not do, or does differently.
- [PORTING.md](../PORTING.md): how the translation is organised.

[soju]: https://soju.im
[ada-on-alpine]: https://github.com/moebiusV/ada-on-alpine
[OFTC]: https://www.oftc.net

---

See also: [README](../README.md) (all documents), [getting started](getting-started.md),
[differences from soju](differences.md), the manual pages
[`soja.1`](soja.1), [`sojadb.1`](sojadb.1) and
[`sojactl.1`](sojactl.1), [PORTING.md](../PORTING.md),
[SOJU-BUGS.md](../SOJU-BUGS.md).
