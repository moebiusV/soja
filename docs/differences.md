# Differences from soju

soja is written to be a drop-in replacement. Where it is not, this page says
so. Everything else (configuration file, database schema, BouncerServ commands,
IRC extensions, wire behaviour) is meant to be the same; if you find a
difference that is not listed here, it is a bug in soja.

## Not yet implemented

- **Source address per user** (`upstream-user-ip`): the directive is read but
  upstream connections leave from the default address.

## Works, but not identically

- **Program names.** `soju` is `soja`, `sojuctl` is `sojactl`, `sojudb` is
  `sojadb`. Paths (`/etc/soju/config`, `./soju.db`, `/run/soju/admin`) are
  soju's.
- **`certfp generate`.** RSA keys are 2048, 3072 (the default) or 4096 bits,
  not any size up to 8192; `ecdsa` is P-384, not P-521; the certificate is
  issued by a throwaway certificate authority, because the cryptographic
  library cannot make a client certificate that signs itself. IRC servers
  check the fingerprint, not the issuer, so this does not matter in practice.
- **`auth oauth2`.** The authorization server is discovered when `soja`
  starts, and not again on `SIGHUP`.
- **`auth pam`.** libpam is loaded when `soja` starts. Without it, `soja`
  refuses to start with this driver.
- **File upload** (`file-upload fs`): a chunked request body is refused;
  conditional requests (`If-Modified-Since`) are not handled; a request for
  several byte ranges at once gets the whole file; the system's `mime.types`
  is not read, so some extensions are recognised by their content instead.
- **Prometheus** (`listen http+prometheus://localhost:<port>`): only the
  `soju_*` metrics are served, not the `go_*`, `process_*` and `promhttp_*` metrics of the Go runtime.
- **Web Push.** Each broadcast is sent by its own task, and a message is one
  encrypted record; the protocol on the wire is the same.

## Bugs in soju that soja fixes

soju has some bugs that soja does not copy, because a drop-in replacement
should not reproduce a crash or a message lost. They are listed, with where in
soju's source each is, in [SOJU-BUGS.md](../SOJU-BUGS.md); each is to be sent
to soju as its own patch. Examples: a failed authentication that the client is
never told about, `user delete <your own name>` hanging, `splitWords`
dropping a word that ends in an escaped space, and ISUPPORT `-TOKEN` negations
being ignored.

## Not yet verified

soja has not yet been used long-term against live networks; it has been tested
against a local ngircd (registration, channels, replay, history, read markers,
SASL, TLS, file upload, WebSockets, Web Push, OAuth 2, PAM) and against fake
servers for the rest. Please report what you find.

---

See also: [README](../README.md) (all documents), [getting started](getting-started.md),
[differences from soju](differences.md), the manual pages
[`soja.1.scd`](soja.1.scd), [`sojadb.1.scd`](sojadb.1.scd) and
[`sojactl.1.scd`](sojactl.1.scd), [PORTING.md](../PORTING.md),
[SOJU-BUGS.md](../SOJU-BUGS.md).
