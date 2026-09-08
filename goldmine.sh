#!/bin/sh
# goldmine.sh: build recipes and maintain the repo.
#
#   host, root   goldmine.sh run [-n]                       repo pull; container build + repo add for every
#                                                            recipe version the repo lacks; repo push (-n: only say)
#                goldmine.sh container init <arch|deb>      create the build chroot under /var/lib/machines
#                goldmine.sh container update <arch|deb>    pacman -Syu / apt dist-upgrade in it
#                goldmine.sh container build <arch|deb> <recipe> [makepkg args]
#                                                            init if missing, update, build in a throwaway overlay
#   inside       goldmine.sh build <arch|deb> <recipe> [makepkg args]
#                                                            what `container build` runs: install build deps,
#                                                            drop privileges, build; unprivileged it just builds
#   host         goldmine.sh repo pull                      _work/repo <- bucket (the bucket is the truth)
#                goldmine.sh repo add <pkg>...              sign and index built packages into _work/repo
#                goldmine.sh repo push                      _work/repo -> bucket
#
# Everything the script writes lives under _work/ (git-ignored): cache/
# (upstream tarballs in dist/, cargo/, rustup/, the distro package cache in
# pkg/<distro>/), out/ (build results) and repo/ (the published tree).
#
# `container build` binds this repo read-only at /build, _work/cache at
# /cache, _work/out at /out, and runs `build` as root inside; that
# refreshes the package index and installs the recipe's build dependencies
# into the overlay, then re-execs as the uid and gid that own /out, so
# nothing builds as root (makepkg refuses to anyway) and results belong to
# whoever owns _work/ on the host. Both containers run under a private user
# namespace (-U): root inside is an unprivileged uid on the host, and the
# binds carry the idmap option so uids on them match the host's. The base
# image is only changed by `container update`; run it now and then.
#
# Run as root (sudo), `repo` drops to the owner of _work/ the same way, so
# the signing key comes from that user's keyring and repo/ stays theirs.
# `run` is the unattended whole: root for the containers, and it calls the
# `repo` steps as child processes so they drop the same way.
#
# Site settings come from .env next to this script (see .env.example):
# GOLDMINE_KEY (signing key), GOLDMINE_REMOTE (rclone remote:bucket) and
# RCLONE_CONFIG (rclone's own variable, the config holding that remote).
#
# `build` runs natively too, for quick checks on a workstation: CACHE and OUT
# name the paths, build deps are assumed present, the work dir is a mktemp
# under /tmp.
#
# POSIX sh plus `local`, which dash, bash and busybox all have.
# shellcheck disable=SC3043

set -eu

root=$( CDPATH='' cd -- "$( dirname -- "$0" )" && pwd )
work_root=$root/_work
cache=${CACHE:-/cache}
out=${OUT:-/out}

# .env is shell syntax, exported wholesale so rclone sees RCLONE_CONFIG.
if [ -f "$root/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$root/.env"
  set +a
fi

# need_env VAR...: refuse to go on without a setting from .env.
need_env() {
  local var
  for var; do
    if eval "[ -z \"\${$var:-}\" ]"; then
      echo "$var is not set: put it in $root/.env (see .env.example)" >&2
      exit 1
    fi
  done
}

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# distro_check NAME: arch|deb, with debian accepted for deb.
distro_check() {
  case $1 in
    arch )         printf 'arch\n' ;;
    deb | debian ) printf 'deb\n' ;;
    * )
      echo "unknown distro: $1 (arch|deb)" >&2
      exit 2
      ;;
  esac
}

# --- recipe helpers ---------------------------------------------------------
# All take the recipe directory in $recipe.

# getval KEY: value of KEY from $recipe/sources (plain key=value, no shell).
getval() { sed -n "s/^$1=//p" "$recipe/sources"; }

# source_names: NAME of every NAME_url entry in $recipe/sources, in file
# order. The first is the main tarball; the rest are components that unpack
# into a subdirectory of that name (Debian: orig-NAME component tarballs).
source_names() { sed -n 's/^\([A-Za-z0-9]*\)_url=.*/\1/p' "$recipe/sources"; }

# src_file NAME URL: file name for URL in the download cache. It is the
# URL's basename, prefixed with "NAME-" unless the basename already starts
# with it. The PKGBUILD's "name::url" entries follow the same rule, and
# makepkg's SRCDEST is pointed at the cache, so both builders share files:
#   haproxy    https://.../haproxy-3.4.3.tar.gz     -> haproxy-3.4.3.tar.gz
#   quictls    https://.../archive/<sha>.tar.gz     -> quictls-<sha>.tar.gz
#   ferrometer https://.../refs/tags/v0.5.0.tar.gz  -> ferrometer-v0.5.0.tar.gz
src_file() {
  case ${2##*/} in
    "$1"-* ) printf '%s\n' "${2##*/}" ;;
    * )      printf '%s-%s\n' "$1" "${2##*/}" ;;
  esac
}

# fetch_url FILE URL SHA256 [DEST]
# Downloads URL to $cache/dist/FILE once, verifies the hash on every call,
# and copies the file to DEST when given.
fetch_url() {
  local file url sum actual
  file=$cache/dist/$1 url=$2 sum=$3
  if [ ! -f "$file" ]; then
    mkdir -p "$cache/dist"
    curl -fsSL --retry 3 -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  actual=$( sha256sum "$file" | cut -d' ' -f1 )
  if [ "$actual" != "$sum" ]; then
    echo "$1: hashes to $actual, expected $sum" >&2
    exit 1
  fi
  [ $# -lt 4 ] || cp "$file" "$4"
}

# fetch_source NAME [DEST]: fetch_url for the NAME_url/NAME_sha256 pair.
fetch_source() {
  local url
  url=$( getval "$1_url" )
  fetch_url "$( src_file "$1" "$url" )" "$url" "$( getval "$1_sha256" )" ${2:+"$2"}
}

# recipe_meta: sets $pkg, $version (Debian revision included) and $upstream
# from debian/changelog, then checks the recipe agrees with itself: the
# PKGBUILD (via .SRCINFO, never sourced) carries the same upstream version,
# and the main source URL names it. Uses sed, not dpkg-parsechangelog, so it
# also runs in the Arch chroot.
recipe_meta() {
  local pkgver main
  pkg=$( sed -n '1s/^\([^ ]*\) .*/\1/p' "$recipe/debian/changelog" )
  version=$( sed -n '1s/^[^(]*(\([^)]*\)).*/\1/p' "$recipe/debian/changelog" )
  upstream=${version%-*}
  if [ -z "$pkg" ] || [ -z "$version" ]; then
    echo "debian/changelog: cannot parse the first line" >&2
    exit 1
  fi
  if [ -f "$recipe/.SRCINFO" ]; then
    pkgver=$( sed -n 's/^\tpkgver = //p' "$recipe/.SRCINFO" )
    if [ "$pkgver" != "$upstream" ]; then
      echo ".SRCINFO pkgver is $pkgver but debian/changelog says $upstream; bump both" >&2
      exit 1
    fi
  fi
  main=$( source_names | head -n 1 )
  case $( getval "${main}_url" ) in
    *"$upstream"* ) ;;
    * )
      echo "sources: ${main}_url does not name version $upstream from debian/changelog" >&2
      exit 1
      ;;
  esac
}

# --- build (inside the container, or natively) ------------------------------

# srcinfo_deps: depends, makedepends and checkdepends from .SRCINFO, one per
# line. The host never sources a PKGBUILD.
srcinfo_deps() { sed -n 's/^\t\(make\|check\)\{0,1\}depends = //p' "$recipe/.SRCINFO"; }

# host_arch DISTRO: this machine's architecture in the distro's package naming.
host_arch() {
  case $1:$( uname -m ) in
    arch:* )      uname -m ;;
    deb:x86_64 )  echo amd64 ;;
    deb:aarch64 ) echo arm64 ;;
    * )
      echo "unsupported architecture $( uname -m )" >&2
      exit 1
      ;;
  esac
}

# distro_version DISTRO: the version the recipe builds, as that distro
# writes it: Arch [epoch:]pkgver-pkgrel from .SRCINFO, Debian from the
# changelog.
distro_version() {
  local epoch
  case $1 in
    arch )
      epoch=$( sed -n 's/^\tepoch = //p' "$recipe/.SRCINFO" )
      printf '%s%s-%s\n' "${epoch:+$epoch:}" \
        "$( sed -n 's/^\tpkgver = //p' "$recipe/.SRCINFO" )" \
        "$( sed -n 's/^\tpkgrel = //p' "$recipe/.SRCINFO" )"
      ;;
    deb ) printf '%s\n' "$version" ;;
  esac
}

# expected_files DISTRO: the package files the recipe produces on this
# machine, one per line, debug packages excluded (never published). Arch
# from .SRCINFO (split packages, epoch, arch=any); Debian from the Package
# stanzas of debian/control (Architecture: all, epoch stripped as dpkg does).
expected_files() {
  local carch
  case $1 in
    arch )
      if sed -n 's/^\tarch = //p' "$recipe/.SRCINFO" | grep -qx any; then
        carch=any
      else
        carch=$( host_arch arch )
      fi
      sed -n 's/^pkgname = //p' "$recipe/.SRCINFO" | while read -r name; do
        printf '%s-%s-%s.pkg.tar.zst\n' "$name" "$( distro_version arch )" "$carch"
      done
      ;;
    deb )
      awk -v arch="$( host_arch deb )" -v ver="${version#*:}" '
        /^Package:/ { pkg = $2; a = arch }
        /^Architecture: all$/ { a = "all" }
        /^$/ && pkg { print pkg "_" ver "_" a ".deb"; pkg = "" }
        END { if (pkg) print pkg "_" ver "_" a ".deb" }' "$recipe/debian/control"
      ;;
  esac
}

# sync_deps DISTRO: install the recipe's build dependencies. Root only; in
# the overlay they vanish with the container. The package index is
# refreshed first so a base that has not seen `container update` for a
# while still resolves current package files; the base itself is left
# alone.
sync_deps() {
  case $1 in
    arch )
      # shellcheck disable=SC2046  # one dependency per word
      pacman -Sy --needed --noconfirm $( srcinfo_deps )
      ;;
    deb )
      apt-get update
      apt-get build-dep -y "$recipe"
      ;;
  esac
}

# drop_privileges DIR ARGS...: re-exec as the owner of DIR when running as
# root. Inside a container the user is created on the spot (in the
# throwaway overlay), named after an existing entry if the uid is taken; on
# the host it is whoever owns _work/.
drop_privileges() {
  local dir uid gid user
  dir=$1
  shift
  mkdir -p "$dir"
  uid=$( stat -c %u "$dir" )
  gid=$( stat -c %g "$dir" )
  if [ "$uid" -eq 0 ]; then
    echo "$dir is owned by root; chown it to the user this should run as" >&2
    exit 1
  fi
  getent group "$gid" >/dev/null || groupadd -g "$gid" builder
  user=$( getent passwd "$uid" | cut -d: -f1 )
  if [ -z "$user" ]; then
    useradd -m -u "$uid" -g "$gid" -d /home/builder builder
    user=builder
  fi
  HOME=$( getent passwd "$user" | cut -d: -f6 )
  export HOME
  exec setpriv --reuid="$uid" --regid="$gid" --clear-groups "$0" "$@"
}

# build_setup: throwaway work dir; Rust's toolchain and registry caches on
# the persistent cache so a rebuild does not refetch the world (harmless for
# other recipes; preset values win, for running natively: a rustup-managed
# host wants RUSTUP_HOME=~/.rustup, an empty one has no toolchain).
build_setup() {
  work=$( mktemp -d )
  trap 'rm -rf "$work"' EXIT
  CARGO_HOME=${CARGO_HOME:-$cache/cargo} RUSTUP_HOME=${RUSTUP_HOME:-$cache/rustup}
  export CARGO_HOME RUSTUP_HOME
}

# Extra arguments go to makepkg: -f to rebuild an existing version, -o to
# only fetch and unpack, -d to skip the dependency check.
build_arch() {
  local name
  build_setup

  # makepkg writes nowhere near the read-only recipe dir: sources come from
  # SRCDEST (the shared cache), src/pkg trees go to BUILDDIR, packages to
  # PKGDEST.
  makepkg() {
    BUILDDIR="$work/build" SRCDEST="$cache/dist" PKGDEST="$out" command makepkg "$@"
  }

  # The host reads .SRCINFO and never the PKGBUILD, so they must agree.
  mkdir -p "$out" "$cache/dist" "$work/build"
  (cd "$recipe" && makepkg --printsrcinfo) >"$work/srcinfo"
  if ! diff -q "$work/srcinfo" "$recipe/.SRCINFO" >/dev/null; then
    echo ".SRCINFO is stale: run 'makepkg --printsrcinfo > .SRCINFO' and commit it" >&2
    exit 1
  fi

  for name in $( source_names ); do
    fetch_source "$name"
  done

  cd "$recipe"
  makepkg "$@"
  ls -l "$out"
}

build_deb() {
  local main comp
  build_setup

  # First entry in sources is the orig tarball, the rest are components:
  # <pkg>_<ver>.orig-<name>.tar.gz, unpacked into <name>/ the way
  # dpkg-source does. Every tarball is used unchanged; dpkg-source strips
  # whatever single top-level directory it carries.
  # shellcheck disable=SC2046  # names are single words
  set -- $( source_names )
  main=$1
  shift
  fetch_source "$main" "$work/${pkg}_$upstream.orig.tar.gz"
  for comp; do
    fetch_source "$comp" "$work/${pkg}_$upstream.orig-$comp.tar.gz"
  done

  cd "$work"
  mkdir -p "$pkg-$upstream"
  tar -xzf "${pkg}_$upstream.orig.tar.gz" -C "$pkg-$upstream" --strip-components=1
  for comp; do
    mkdir -p "$pkg-$upstream/$comp"
    tar -xzf "${pkg}_$upstream.orig-$comp.tar.gz" -C "$pkg-$upstream/$comp" --strip-components=1
  done
  # debian/ on top, dereferenced (recipes may symlink to shared files). An
  # upstream tree that ships its own debian/ (ferrometer does) must not
  # leak into ours, so drop it first instead of merging.
  rm -rf "$pkg-$upstream/debian"
  cp -rL "$recipe/debian" "$pkg-$upstream/"

  cd "$pkg-$upstream"
  dpkg-buildpackage --unsigned-source --unsigned-changes --jobs=auto
  cd ..

  lintian --info "${pkg}_${version}"_*.changes || true

  mkdir -p "$out"
  cp -- *.deb *.dsc *.tar.* *.changes *.buildinfo "$out/"
  ls -l "$out"
}

cmd_build() {
  local distro
  [ $# -ge 2 ] || usage
  distro=$( distro_check "$1" )
  recipe=$( CDPATH='' cd -- "$2" && pwd )
  shift 2
  recipe_meta
  if [ "$( id -u )" -eq 0 ]; then
    sync_deps "$distro"
    drop_privileges "$out" build "$distro" "$recipe" "$@"
  fi
  case $distro in
    arch ) build_arch "$@" ;;
    deb )  [ $# -eq 0 ] || usage; build_deb ;;
  esac
}

# --- host side --------------------------------------------------------------

# work_dirs: _work/ and its subdirectories. Created here they belong to
# sudo's caller, so builds and repo-add can drop to that user; existing
# ones are left as they are.
work_dirs() {
  local dir
  for dir in "$work_root" "$work_root/cache" "$work_root/out" "$work_root/repo"; do
    [ -d "$dir" ] || install -d -o "${SUDO_UID:-$( id -u )}" -g "${SUDO_GID:-$( id -g )}" "$dir"
  done
}

# --- repo -------------------------------------------------------------------

# Regenerates the flat apt repo in _work/repo/debian from its pool: prune,
# index, sign. Stateless, the repo-add(8) analogue.
deb_index() {
  local repo_deb keep name versions f v w newer
  repo_deb=$work_root/repo/debian
  keep=2
  cd "$repo_deb"

  # Retention: the newest $keep versions of each package, in dpkg's version
  # order (epochs and ~ included). Quadratic, and the pool is a handful of
  # files.
  # shellcheck disable=SC2012  # names are [a-z0-9.+-], no surprises
  for name in $( ls pool | sed 's/_.*//' | sort -u ); do
    versions=$( for f in pool/"$name"_*.deb; do f=${f#pool/"$name"_}; printf '%s\n' "${f%_*}"; done | sort -u )
    for v in $versions; do
      newer=0
      for w in $versions; do
        if dpkg --compare-versions "$w" gt "$v"; then newer=$(( newer + 1 )); fi
      done
      if [ "$newer" -ge "$keep" ]; then rm -v pool/"$name"_"$v"_*.deb; fi
    done
  done

  rm -f Release InRelease Release.gpg
  apt-ftparchive packages pool >Packages
  gzip -kf Packages
  # Written outside the tree: apt-ftparchive hashes every index-looking file
  # it finds, Release itself included when it is already there.
  apt-ftparchive -c "$root/debian-release.conf" release . >"$work_root/Release.tmp"
  mv "$work_root/Release.tmp" Release
  gpg -u "$GOLDMINE_KEY" --clearsign -o InRelease Release
  gpg -u "$GOLDMINE_KEY" -abs -o Release.gpg Release
}

repo_add() {
  local repo_arch repo_deb pkg has_deb
  [ $# -ge 1 ] || usage
  need_env GOLDMINE_KEY
  repo_arch=$work_root/repo/archlinux
  repo_deb=$work_root/repo/debian
  has_deb=

  for pkg; do
    case "$pkg" in
      *.pkg.tar.zst )
        mkdir -p "$repo_arch"
        cp -- "$pkg" "$repo_arch/"
        gpg -u "$GOLDMINE_KEY" --batch -sb "$repo_arch/${pkg##*/}"
        repo-add --sign --key "$GOLDMINE_KEY" --verify --remove "$repo_arch/goldmine.db.tar.zst" "$repo_arch/${pkg##*/}"
        printf "Added '%s' to goldmine/archlinux repo\n" "${pkg##*/}"
        ;;
      *.deb )
        has_deb=1
        mkdir -p "$repo_deb/pool"
        cp -- "$pkg" "$repo_deb/pool/"
        printf "Added '%s' to goldmine/debian repo\n" "${pkg##*/}"
        ;;
      * )
        printf "Unknown package type: %s\n" "$pkg" >&2
        exit 1
        ;;
    esac
  done

  if [ -n "$has_deb" ]; then
    ( deb_index )
  fi
}

# The bucket is the truth: pull before add, push after. Both are rclone
# sync, so push deletes from the bucket whatever the local tree lacks; it
# refuses an empty tree rather than emptying the bucket.
repo_pull() {
  need_env GOLDMINE_REMOTE RCLONE_CONFIG
  rclone sync -Lv "$GOLDMINE_REMOTE" "$work_root/repo"
}

repo_push() {
  need_env GOLDMINE_REMOTE RCLONE_CONFIG
  if [ ! -d "$work_root/repo/archlinux" ] && [ ! -d "$work_root/repo/debian" ]; then
    echo "$work_root/repo holds no repository; repo pull first" >&2
    exit 1
  fi
  rclone sync -Lv "$work_root/repo" "$GOLDMINE_REMOTE"
}

cmd_repo() {
  local action
  [ $# -ge 1 ] || usage
  action=$1
  shift
  work_dirs
  if [ "$( id -u )" -eq 0 ]; then
    drop_privileges "$work_root" repo "$action" "$@"
  fi
  case $action in
    pull ) [ $# -eq 0 ] || usage; repo_pull ;;
    add )  repo_add "$@" ;;
    push ) [ $# -eq 0 ] || usage; repo_push ;;
    * )    usage ;;
  esac
}

# --- run (host, root) -------------------------------------------------------

# repo_has DISTRO: every expected package file is in _work/repo.
repo_has() {
  local dir file
  case $1 in
    arch ) dir=$work_root/repo/archlinux ;;
    deb )  dir=$work_root/repo/debian/pool ;;
  esac
  for file in $( expected_files "$1" ); do
    [ -f "$dir/$file" ] || return 1
  done
}

# run_recipe RECIPE DRY: build and add what the repo lacks, for each distro
# the recipe covers. Runs in a subshell of cmd_run so a failure ends this
# recipe and not the run.
run_recipe() {
  local distro file files
  recipe=$1
  recipe_meta
  for distro in arch deb; do
    case $distro in
      arch ) [ -f "$recipe/PKGBUILD" ] || continue ;;
      deb )  [ -d "$recipe/debian" ] || continue ;;
    esac
    if repo_has "$distro"; then
      echo "$pkg $distro: $( distro_version "$distro" ) is in the repo"
      continue
    fi
    if [ -n "$2" ]; then
      echo "$pkg $distro: would build $( distro_version "$distro" )"
      continue
    fi
    echo "$pkg $distro: building $( distro_version "$distro" )"
    case $distro in
      arch ) "$root/goldmine.sh" container build arch "$recipe" -f ;;
      deb )  "$root/goldmine.sh" container build deb "$recipe" ;;
    esac
    files=
    for file in $( expected_files "$distro" ); do
      if [ ! -f "$work_root/out/$file" ]; then
        echo "$pkg $distro: build produced no $file" >&2
        exit 1
      fi
      files="$files $work_root/out/$file"
    done
    # shellcheck disable=SC2086  # paths carry no whitespace
    "$root/goldmine.sh" repo add $files
  done
}

cmd_run() {
  local dry recipe status failed
  dry=
  if [ "${1:-}" = -n ]; then
    dry=1
    shift
  fi
  [ $# -eq 0 ] || usage
  if [ -z "$dry" ] && [ "$( id -u )" -ne 0 ]; then
    echo "run needs root" >&2
    exit 1
  fi
  [ -n "$dry" ] || "$root/goldmine.sh" repo pull

  failed=
  for recipe in "$root"/*/; do
    recipe=${recipe%/}
    [ -f "$recipe/sources" ] || continue
    # A subshell with its own -e: errors end the recipe, the loop goes on.
    set +e
    ( set -e; run_recipe "$recipe" "$dry" )
    status=$?
    set -e
    [ "$status" -eq 0 ] || failed="$failed ${recipe##*/}"
  done

  # Push what did get added even if something else failed.
  [ -n "$dry" ] || "$root/goldmine.sh" repo push
  if [ -n "$failed" ]; then
    echo "failed:$failed" >&2
    exit 1
  fi
}

# --- container (host, root) -------------------------------------------------
# Build chroots under /var/lib/machines: arch-builder from devtools'
# clean-chroot pacman.conf, deb-builder from debootstrap. Debian is the
# oldest release the packages target (bookworm): a .deb built there runs
# on every newer one.

machines=/var/lib/machines
deb_suite=bookworm
deb_mirror=http://deb.debian.org/debian
# rustup for the Debian container: bookworm packages neither rustup nor a
# rustc new enough for our crates. The pinned rustup-init binary is the
# rustup binary; installed as /usr/local/bin/rustup with cargo and rustc
# hardlinks it acts as their proxy, and the toolchains it installs land in
# $RUSTUP_HOME, which the builds point at /cache.
rustup_version=1.29.1
rustup_sha256_x86_64=dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71
rustup_sha256_aarch64=15f6e4ce9f583b929c996c91562bad6d4454f3281de858b02cdfdef615fac433

# container_dir DISTRO: the machine's root directory.
container_dir() { printf '%s/%s-builder\n' "$machines" "$1"; }

# container_run DISTRO [nspawn args --] CMD...: CMD as root inside the
# machine, under a private user namespace.
container_run() {
  local distro
  distro=$1
  shift
  systemd-nspawn -q -U -M "$distro-builder" --pipe --as-pid2 "$@"
}

# install_rustup DIR: pinned rustup into DIR/usr/local/bin with the cargo
# and rustc proxies, for the host's architecture (the chroot is native).
install_rustup() {
  local arch sum bin
  arch=$( uname -m )
  case $arch in
    x86_64 )  sum=$rustup_sha256_x86_64 ;;
    aarch64 ) sum=$rustup_sha256_aarch64 ;;
    * )
      echo "no rustup hash for $arch" >&2
      exit 1
      ;;
  esac
  bin=$1/usr/local/bin/rustup
  curl -fsSL --retry 3 -o "$bin.part" \
    "https://static.rust-lang.org/rustup/archive/$rustup_version/$arch-unknown-linux-gnu/rustup-init"
  if [ "$( sha256sum "$bin.part" | cut -d' ' -f1 )" != "$sum" ]; then
    echo "rustup-init $rustup_version ($arch): hash mismatch" >&2
    exit 1
  fi
  chmod 755 "$bin.part"
  mv "$bin.part" "$bin"
  ln -f "$bin" "$1/usr/local/bin/cargo"
  ln -f "$bin" "$1/usr/local/bin/rustc"
}

container_init() {
  local distro dir conf
  distro=$1
  dir=$( container_dir "$distro" )
  if [ -e "$dir" ]; then
    echo "$dir exists; remove it (machinectl remove $distro-builder) to start over" >&2
    exit 1
  fi
  case $distro in
    arch )
      # devtools' [core]+[extra] config, as Arch's own clean chroots use,
      # with the user hook dir pointed nowhere. mkarchroot installs it as
      # the chroot's /etc/pacman.conf, so it holds for later runs too.
      conf=$( mktemp )
      sed '/^\[options\]/a HookDir = /nonexistent' /usr/share/devtools/pacman.conf.d/extra.conf >"$conf"
      mkarchroot -C "$conf" "$dir" base-devel
      rm -f "$conf"
      ;;
    deb )
      debootstrap --variant=minbase "$deb_suite" "$dir" "$deb_mirror"
      # The suites a stock install tracks, in deb822 form.
      cat >"$dir/etc/apt/sources.list.d/debian.sources" <<SOURCES
Types: deb
URIs: $deb_mirror
Suites: $deb_suite $deb_suite-updates
Components: main

Types: deb
URIs: http://deb.debian.org/debian-security
Suites: $deb_suite-security
Components: main
SOURCES
      rm -f "$dir/etc/apt/sources.list"
      # curl + CA bundle for fetching sources; lintian for the report.
      # Build-Depends come per recipe, at build time.
      container_run deb sh -c '
        apt-get update &&
        apt-get install -y --no-install-recommends curl ca-certificates lintian &&
        apt-get clean'
      install_rustup "$dir"
      ;;
  esac
  echo "$dir ready"
}

container_update() {
  case $1 in
    arch ) container_run arch pacman -Syu --noconfirm ;;
    deb )  container_run deb sh -c 'apt-get update && apt-get -y dist-upgrade && apt-get clean' ;;
  esac
}

# container_build DISTRO RECIPE [makepkg args]: the whole thing. The
# overlay is thrown away with the container; the binds persist. _work/ is
# created for the invoking user (sudo's caller) when missing, so the build
# user inside has somewhere to write.
container_build() {
  local distro recipe rel pkgcache
  distro=$1
  recipe=$( CDPATH='' cd -- "$2" && pwd )
  shift 2
  rel=${recipe#"$root/"}
  if [ "$rel" = "$recipe" ] || [ ! -f "$recipe/sources" ]; then
    echo "$recipe: not a recipe directory in $root" >&2
    exit 1
  fi
  case $distro in
    arch ) pkgcache=/var/cache/pacman/pkg ;;
    deb )  pkgcache=/var/cache/apt/archives ;;
  esac

  [ -d "$( container_dir "$distro" )" ] || container_init "$distro"

  work_dirs
  install -d "$work_root/cache/pkg/$distro"
  container_run "$distro" --volatile=overlay \
    --bind-ro="$root:/build:idmap" \
    --bind="$work_root/cache:/cache:idmap" \
    --bind="$work_root/cache/pkg/$distro:$pkgcache:idmap" \
    --bind="$work_root/out:/out:idmap" \
    -- /build/goldmine.sh build "$distro" "/build/$rel" "$@"
}

cmd_container() {
  local action distro
  [ $# -ge 2 ] || usage
  action=$1
  distro=$( distro_check "$2" )
  shift 2
  if [ "$( id -u )" -ne 0 ]; then
    echo "container $action needs root" >&2
    exit 1
  fi
  case $action in
    init )   [ $# -eq 0 ] || usage; container_init "$distro" ;;
    update ) [ $# -eq 0 ] || usage; container_update "$distro" ;;
    build )  [ $# -ge 1 ] || usage; container_build "$distro" "$@" ;;
    * )      usage ;;
  esac
}

# --- main -------------------------------------------------------------------

[ $# -ge 1 ] || usage
cmd=$1
shift
case $cmd in
  build )     cmd_build "$@" ;;
  run )       cmd_run "$@" ;;
  repo )      cmd_repo "$@" ;;
  container ) cmd_container "$@" ;;
  * )         usage ;;
esac
