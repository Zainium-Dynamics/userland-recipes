#!/bin/sh
# ci/build.sh — turn one recipe directory into .zex file(s).
#
# Usage: ci/build.sh <pkgdir>
#   e.g. ci/build.sh htop
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

# `--prefix=/overlayer/syshub` (see README's "Why --prefix=/overlayer/syshub
# even for userland packages") means `make DESTDIR=$1 install` lands files
# at $1/overlayer/syshub/{bin,lib,...} — DESTDIR prepends the configured
# prefix, it doesn't replace it. substrate needs the flat form
# ($1/{bin,lib,...}) to match manifest.toml's [install] map. Recipes don't
# have to know this — every package()/subpackage function's DESTDIR gets
# flattened right after it runs.
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
#    (exactly what happened once already on an ubuntu-latest runner,
#    which has no real musl toolchain at all — --host="$CHOST" fell
#    back to plain glibc gcc without ever failing the build). Runs
#    after flatten_prefix, before `substrate pack`, so a bad binary
#    fails the build right here instead of getting packed/published.
#    Opt out via `native = true` in manifest.toml (self-hosting
#    toolchain packages with their own already-correct linking).
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
    [ -e "$f" ] && tar xf "$f"
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
