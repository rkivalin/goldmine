# goldmine

Package recipes for the `goldmine` Arch and Debian repositories.

## Packages

| package | | Arch | Debian |
|---|---|:-:|:-:|
| `haproxy-quictls` | HAProxy with QUIC/HTTP3 via a statically linked QuicTLS, Lua scripting, PCRE2 and Prometheus metrics, with a hardened systemd unit | x | x |
| `ferrometer` | Lightweight telemetry collector: system metrics to OTLP, systemd journal to Loki | x | x |
| `certforge` | ACME certificate manager with DANE and systemd integration | x | x |

Every package is built from pinned, hash-checked upstream sources in a
clean chroot of the target distribution; nothing prebuilt is repackaged.
Debian packages are built on bookworm and run on it and anything newer.

## Using the repository

Both repositories are signed with the same key:

```
72E36E2428FA0F83BD2B4A0B3602E340EC677D90  Roman Kivalin (goldmine repository) <roman@shl.dev>
```

It is on `keyserver.ubuntu.com` and in this repository as `goldmine.asc`.

### Arch Linux

```sh
pacman-key --recv-keys 72E36E2428FA0F83BD2B4A0B3602E340EC677D90
pacman-key --lsign-key 72E36E2428FA0F83BD2B4A0B3602E340EC677D90
```

`/etc/pacman.conf`:

```ini
[goldmine]
Server = https://arch.shl.dev/goldmine/archlinux
```

### Debian

```sh
gpg --keyserver keyserver.ubuntu.com --recv-keys 72E36E2428FA0F83BD2B4A0B3602E340EC677D90
gpg --export 72E36E2428FA0F83BD2B4A0B3602E340EC677D90 > /etc/apt/keyrings/goldmine.gpg
```

(or `gpg --dearmor < goldmine.asc > /etc/apt/keyrings/goldmine.gpg` from a
checkout). `/etc/apt/sources.list.d/goldmine.sources`:

```
Types: deb
URIs: https://arch.shl.dev/goldmine/debian
Suites: /
Signed-By: /etc/apt/keyrings/goldmine.gpg
```

It is a flat repository: `Suites: /`, no components. The last two
versions of each package are kept, so the previous one can be pinned.

## Bumping a package

Each package is one directory holding both distributions' packaging. To
move it to a new upstream version:

1. `sources`: the new tarball URL and the sha256 of the downloaded file
   (HAProxy publishes it next to the tarball as `<name>.tar.gz.sha256`;
   GitHub tag exports are hashed after download).
2. `debian/changelog`: a new entry, `<upstream>-1` (`dch -v` or by hand).
3. `PKGBUILD`: `pkgver`, `pkgrel=1`, the same hashes; then
   `makepkg --printsrcinfo > .SRCINFO`.
4. Check the build inputs still hold: `debian/control` Build-Depends and
   `makedepends`, the shipped unit and config files, Rust MSRV against the
   toolchain.
5. Build both, install the result somewhere, and only then publish.

A packaging-only change bumps `pkgrel` and the Debian revision instead.
The build refuses a recipe whose `sources`, `PKGBUILD`/`.SRCINFO` and
`debian/changelog` disagree on the version, and a version already in the
repository is never rebuilt, so a change without a bump publishes nothing.

## Building and publishing

`goldmine.sh` does all of it: build chroots under `/var/lib/machines`,
builds in throwaway containers, signing and indexing, sync with the bucket.
`./goldmine.sh` with no arguments prints the commands, and the comment
block at the top of the script explains how the pieces fit. Site settings
(signing key, rclone remote and config) come from `.env`, see
`.env.example`.
