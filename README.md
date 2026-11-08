# soja

[Index: All Projects](https://moebiusv.github.io/) | [github.com/moebiusV/soja](https://github.com/moebiusV/soja) | `git clone https://github.com/moebiusV/soja`

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

Early — the translation proceeds module by module from `upstream/soju`.

## Build

```
# inside the ada-on-alpine container
gprbuild -P soja.gpr
```

## License

AGPL-3.0, inherited from soju (soja is a translation of soju). See `LICENSE`.
