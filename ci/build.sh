#!/bin/sh
# ci/build.sh — turn one recipe directory into .zex file(s).
#
# Usage: ci/build.sh <pkgdir>
#   e.g. ci/build.sh gcc
#
# Identical to userland-recipes' ci/build.sh — the only thing that
# differs between a userland and a syshub package is manifest.toml's
# `_syshub` flag (and install paths), which zex-ports publish already
# routes on. Nothing here needs to know which kind of package it's
# building.
#
# Env this script expects the CI job to set:
#   CHOST            — target triple, e.g. x86_64-zainium-linux-musl
#   REQUIRES_SYSHUB   — value passed to `substrate pack --requires-syshub`
#   SUBSTRATE          — path to the substrate binary (falls back to `substrate` on PATH)
#   PUBLISH           — "1" to also run `zex-ports publish` on each .zex (release
#                        stage only — the check stage leaves this unset, build-only)
#
# On success, the finished .zex file(s) are left in $CI_PROJECT_DIR (repo root),
# one per package/subpackage. Everything under .zexbuild-staging/ is scratch
# space — never declared as a GitLab CI `artifacts:` path, so it's discarded
# with the rest of the job workspace once the job ends.

set -eu

PKGDIR="${1:?usage: ci/build.sh <pkgdir>}"
: "${CHOST:=x86_64-zainium-linux-musl}"
: "${SUBSTRATE:=substrate}"

OUT_DIR="$(pwd)"
RECIPE_DIR="$(pwd)/$PKGDIR"
STAGING_ROOT="$(pwd)/.zexbuild-staging/$PKGDIR"
SRCDIR="$STAGING_ROOT/src"

[ -f "$RECIPE_DIR/ZEXBUILD" ] || { echo "no ZEXBUILD in $PKGDIR" >&2; exit 1; }

rm -rf "$STAGING_ROOT"
mkdir -p "$SRCDIR"

# ── source the recipe — pkgname/pkgver/build()/package()/etc. become
#    plain shell variables and functions from here on ──────────────────
# shellcheck disable=SC1091
. "$RECIPE_DIR/ZEXBUILD"

: "${pkgname:?ZEXBUILD did not set pkgname}"
: "${pkgver:?ZEXBUILD did not set pkgver}"
: "${pkgrel:=0}"

echo "== $pkgname $pkgver-$pkgrel =="

# Alpine-style: each recipe declares its own extra apk deps instead of
# CI growing a global list.
[ -n "${makedepends:-}" ] && apk add --no-cache $makedepends

# Zainium's own musl loader has to actually exist on this Alpine host
# before LDFLAGS points -Wl,-dynamic-linker at it — otherwise every
# ./configure's own "can I run a compiled test program" self-check
# fails ("cannot run C compiled programs"), since autoconf executes
# what it just compiled right here on the build host. Force musl into
# needs_toolchain unconditionally (install_toolchain_deps below) so
# every recipe gets a real, working loader at that path, not just the
# ones that already declared musl as a toolchain dep.
ZAINIUM_LDSO="/overlayer/syshub/x86_64-zainium-linux-musl/lib/ld-musl-x86_64.so.1"
case " ${needs_toolchain:-} " in
    *" musl "*) ;;
    *) needs_toolchain="musl ${needs_toolchain:-}" ;;
esac

# Self-hosting toolchain packages (gcc-16, binutils, ...) need an
# already-published Zainium toolchain installed into /overlayer/syshub
# before they can build at all — set needs_toolchain="pkg1 pkg2 ..." in
# ZEXBUILD (package NAMES, not filenames/versions) to have this fetched
# automatically from the live syshub ledger. New recipes needing this
# just declare it — no CI changes required.
install_toolchain_deps() {
    for pkg in ${needs_toolchain:-}; do
        echo "-- installing toolchain dependency: $pkg --"
        # Try the syshub ledger first, then userland — a toolchain dep can
        # be either tier (e.g. binutils needs zstd's *headers*, which live
        # in zstd-dev, a userland -dev subpackage, not the syshub runtime
        # package). Package NAME is all a recipe declares; which tier it
        # actually lives in is this function's problem, not the recipe's.
        file=""
        for tier_url in \
            "https://archive.zainiumdynamics.tech/core/syshub/x86_64/syshub.toml|core/syshub/x86_64/packages" \
            "https://archive.zainiumdynamics.tech/userland/x86_64/zex_ledger-x86_64.toml|userland/x86_64/packages"
        do
            ledger_url="${tier_url%%|*}"
            pkgs_path="${tier_url##*|}"
            # `|| true` — under `set -e`, a failed fetch (e.g. a syshub-only
            # pkg 404ing against the userland ledger, or vice versa) would
            # otherwise abort the whole script right here, silently, before
            # the loop ever gets to try the other tier or print anything.
            ledger="$(wget -qO- "$ledger_url" 2>/dev/null || true)"
            file="$(printf '%s\n' "$ledger" | sed -n "/^\[packages.$pkg\]\$/,/^\$/p" | sed -n 's/^file *= *"\(.*\)"/\1/p')"
            if [ -n "$file" ]; then
                base_url="https://archive.zainiumdynamics.tech/$pkgs_path"
                break
            fi
        done
        [ -n "$file" ] || { echo "toolchain dep $pkg: not found in syshub or userland ledger" >&2; exit 1; }
        echo "  -> $file"
        wget -qO "/tmp/$file" "$base_url/$file"
        "$SUBSTRATE" unpack "/tmp/$file" --output /overlayer/syshub
    done

    # gcc-musl's own cc1 was built with --enable-lto, which links it
    # against libzstd.so.1 *unconditionally* (GCC's LTO bytecode writer is
    # compiled into cc1 itself, not a plugin) — cc1 can't run at all,
    # LTO or not, until that .so exists somewhere on its search path. No
    # zainium-native libzstd is published yet (this is exactly what the
    # zstd recipe is for), so borrow Alpine's own musl-linked libzstd.so.1
    # here just to get cc1 off the ground. musl's ABI is stable across
    # independent builds of the same libc, so this is safe for a library
    # that only calls ordinary libc functions (malloc/memcpy/...) — once
    # cc1 can run, the zstd recipe builds and packages Zainium's own
    # native libzstd.so.1 for real, which is what actually ships. This
    # only ever fires when gcc-musl was requested and nothing has already
    # put a real libzstd.so.1 at this path (i.e. becomes a no-op forever
    # once the zstd package itself is in needs_toolchain).
    case " ${needs_toolchain:-} " in
        *" gcc-musl "*)
            if [ ! -e /overlayer/syshub/lib/libzstd.so.1 ]; then
                echo "-- bootstrapping libzstd.so.1 from Alpine (cc1 needs it to run at all) --"
                apk add --no-cache zstd-libs >/dev/null
                mkdir -p /overlayer/syshub/lib
                cp -L /usr/lib/libzstd.so.1 /overlayer/syshub/lib/libzstd.so.1
            fi
            ;;
    esac
}
install_toolchain_deps

# musl is real now (just unpacked above) — safe to point every
# recipe's LDFLAGS/RUSTFLAGS at Zainium's actual loader.
export LDFLAGS="${LDFLAGS:-} -Wl,-dynamic-linker=$ZAINIUM_LDSO -Wl,-rpath=/overlayer/syshub/lib"
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="${CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS:-} -C link-arg=-Wl,-dynamic-linker=$ZAINIUM_LDSO -C link-arg=-Wl,-rpath=/overlayer/syshub/lib"

# Some builds run their own just-compiled tool mid-build (wayland's
# wayland-scanner generating protocol headers, e.g.) — that tool now
# carries Zainium's interpreter/rpath too, so it needs its *other*
# runtime libs (not just musl) to already exist under
# /overlayer/syshub/lib, same problem the gcc-musl/libzstd bootstrap
# above solves. Same justification: musl's ABI is stable across
# independent builds of the same libc, so borrowing Alpine's own copy
# of a plain C library is safe. Extend this list as new build-time
# tools surface a new missing one.
for lib in libz.so.1 liblzma.so.5 libexpat.so.1 libxml2.so.2; do
    [ -e "/overlayer/syshub/lib/$lib" ] && continue
    src="$(find /usr/lib /lib -maxdepth 1 -name "$lib" 2>/dev/null | head -1)"
    [ -n "$src" ] || continue
    echo "-- bootstrapping $lib from Alpine (a build-time tool needs it to run) --"
    mkdir -p /overlayer/syshub/lib
    cp -L "$src" "/overlayer/syshub/lib/$lib"
done

# `--prefix=/overlayer/syshub` is the runtime-visible merged path for
# EVERY package, syshub or userland (see userland-recipes' README's "Why
# --prefix=/overlayer/syshub even for userland packages") — DESTDIR
# prepends the configured prefix, it doesn't replace it. substrate needs
# the flat form ($1/{bin,lib,...}) to match manifest.toml's [install]
# map. Recipes don't have to know this — every package()/subpackage
# function's DESTDIR gets flattened right after it runs.
flatten_prefix() {
    dir="$1"
    if [ -d "$dir/overlayer/syshub" ]; then
        (cd "$dir/overlayer/syshub" && find . -mindepth 1 -maxdepth 1 -exec mv {} "$dir/" \;)
        rm -rf "$dir/overlayer"
    fi
}

# ── verify: every ELF in the payload is actually musl-linked, with its
#    interpreter under /overlayer/syshub — not a glibc binary that
#    silently built anyway because $CHOST's cross-compiler wasn't found
#    (exactly what happened once already on userland-recipes' original
#    ubuntu-latest runner, which had no real musl toolchain at all —
#    --host="$CHOST" fell back to plain glibc gcc without ever failing
#    the build). Runs after flatten_prefix, before `substrate pack`, so
#    a bad binary fails the build right here instead of getting
#    packed/published. Opt out via `native = true` in manifest.toml
#    (self-hosting toolchain packages — e.g. gcc-musl-cross itself —
#    that already compiled with their own correct, final linking).
verify_musl() {
    dir="$1"
    manifest="$2"

    if grep -Eq '^[[:space:]]*native[[:space:]]*=[[:space:]]*true' "$manifest" 2>/dev/null; then
        echo "-- manifest.toml: native = true, skipping musl verification --"
        return 0
    fi

    echo "-- verifying musl / interpreter / prefix under ${dir#"$(pwd)"/} --"
    fail_marker="$STAGING_ROOT/.verify-failed"
    rm -f "$fail_marker"

    find "$dir" -type f -perm -u+x -print | while IFS= read -r f; do
        magic="$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')"
        [ "$magic" = "7f454c46" ] || continue

        interp="$(readelf -l "$f" 2>/dev/null | sed -n 's/.*interpreter: \([^]]*\).*/\1/p')"
        rel="${f#"$dir"/}"

        echo "  $rel"
        echo "    prefix      : ${dir}"
        echo "    interpreter : ${interp:-<none - static or not a dynamic exe>}"

        if readelf -d "$f" 2>/dev/null | grep -q 'NEEDED.*libc\.so\.6'; then
            echo "    FAIL: linked against GLIBC (libc.so.6), not musl"
            touch "$fail_marker"
            continue
        fi

        if [ -n "$interp" ]; then
            case "$interp" in
                /overlayer/syshub/*ld-musl-*) ;;
                *)
                    echo "    FAIL: interpreter is not the Zainium musl loader under /overlayer/syshub: $interp"
                    touch "$fail_marker"
                    continue
                    ;;
            esac
        fi

        echo "    OK"
    done

    if [ -f "$fail_marker" ]; then
        rm -f "$fail_marker"
        echo "musl/interpreter verification FAILED for $pkgname — see FAIL lines above"
        exit 1
    fi
    echo "-- musl verification passed --"
}

# ── fetch + verify each URL entry in $source ─────────────────────────
cd "$SRCDIR"
for entry in ${source:-}; do
    case "$entry" in
        http://*|https://*)
            fname="${entry##*/}"
            wget -q -O "$fname" "$entry"
            ;;
        *)
            # local file (patch, install script, ...) — sits next to ZEXBUILD
            cp "$RECIPE_DIR/$entry" .
            ;;
    esac
done
if [ -n "${sha256sums:-}" ]; then
    echo "$sha256sums" | sha256sum -c -
fi

# Convention: the fetched tarball extracts to ./<pkgname>-<pkgver>/ and
# that's where build() runs. Recipes that don't fit this (odd tarball
# root name, git source, etc.) can override by cd-ing themselves inside
# build() — this is just the common-case default.
for f in *.tar.*; do
    [ -e "$f" ] || continue
    case "$f" in
        # Alpine's default `tar` is BusyBox's, not GNU tar — it doesn't
        # auto-detect/decompress zstd (fails with "invalid tar magic")
        # even with the zstd CLI on PATH. Pipe through zstd explicitly
        # instead of relying on tar's own compression-format support.
        *.tar.zst) zstd -dc "$f" | tar xf - ;;
        *)         tar xf "$f" ;;
    esac
done
cd "$pkgname-$pkgver" 2>/dev/null || true

# ── build ──────────────────────────────────────────────────────────────
build

# ── package: main payload ─────────────────────────────────────────────
PAYLOAD_DIR="$STAGING_ROOT/pkg/payload"
mkdir -p "$PAYLOAD_DIR"
package
flatten_prefix "$PAYLOAD_DIR"

cp "$RECIPE_DIR/manifest.toml" "$STAGING_ROOT/pkg/manifest.toml"
verify_musl "$PAYLOAD_DIR" "$STAGING_ROOT/pkg/manifest.toml"

echo "-- packing $pkgname --"
# Not piped through `tail` directly — in plain POSIX sh (no pipefail),
# a pipe's exit status is the LAST command's (tail, which always
# succeeds), so a failing `pack` would be silently swallowed and the
# script would carry on to publish a .zex that was never produced.
pack_log="$STAGING_ROOT/pack-$pkgname.log"
if ! "$SUBSTRATE" pack -v "$pkgver" --requires-syshub "${REQUIRES_SYSHUB:-}" \
    "$STAGING_ROOT/pkg" -o "$OUT_DIR/$pkgname-$pkgver.zex" \
    > "$pack_log" 2>&1
then
    tail -30 "$pack_log"
    exit 1
fi
tail -10 "$pack_log"

# ── subpackages, if any ────────────────────────────────────────────────
for sub in ${subpackages:-}; do
    subfn="${sub#"$pkgname"-}"   # "$pkgname-dev" -> "dev"
    SUBPKG_PAYLOAD_DIR="$STAGING_ROOT/subpkg/$sub/payload"
    mkdir -p "$SUBPKG_PAYLOAD_DIR"
    # Subpackage functions (dev(), etc.) stage into $PAYLOAD_DIR same as
    # package() does — without repointing it here it would still hold the
    # main package's (already-finished) payload dir, silently writing the
    # subpackage's files into the wrong package.
    PAYLOAD_DIR="$SUBPKG_PAYLOAD_DIR"
    "$subfn"
    flatten_prefix "$SUBPKG_PAYLOAD_DIR"

    cp "$RECIPE_DIR/$sub.manifest.toml" "$STAGING_ROOT/subpkg/$sub/manifest.toml"
    verify_musl "$SUBPKG_PAYLOAD_DIR" "$STAGING_ROOT/subpkg/$sub/manifest.toml"

    echo "-- packing $sub --"
    sub_pack_log="$STAGING_ROOT/pack-$sub.log"
    if ! "$SUBSTRATE" pack -v "$pkgver" --requires-syshub "${REQUIRES_SYSHUB:-}" \
        "$STAGING_ROOT/subpkg/$sub" -o "$OUT_DIR/$sub-$pkgver.zex" \
        > "$sub_pack_log" 2>&1
    then
        tail -30 "$sub_pack_log"
        exit 1
    fi
    tail -10 "$sub_pack_log"
done

if [ "${PUBLISH:-}" = "1" ]; then
    for zex in "$pkgname-$pkgver.zex" ${subpackages:+$(for s in $subpackages; do echo "$s-$pkgver.zex"; done)}; do
        echo "-- publishing $zex --"
        zex-ports publish "$OUT_DIR/$zex"
    done
fi
