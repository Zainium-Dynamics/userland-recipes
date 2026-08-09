# userland-recipes

Community package recipes for Zainium OS userland — fork, add a recipe, open a merge request. Review *is* the MR review; once it's merged, CI builds it, packs it with [`substrate`](https://gitlab.com/alizain.arch/substrate), and publishes it to the package repository. No separate website upload/approval step.

Modeled on Alpine's [aports](https://gitlab.alpinelinux.org/alpine/aports) — a `ZEXBUILD` here plays the same role an `APKBUILD` plays there.

## Adding a package

1. Fork this repo.
2. Create `<pkgname>/ZEXBUILD` (see format below) and `<pkgname>/manifest.toml`.
3. If you need to patch upstream source, drop `*.patch` files flat next to `ZEXBUILD` (see `htop/` for the layout — not a subfolder, matching aports convention) and apply them explicitly inside `ZEXBUILD`.
4. Open a merge request. CI runs a build-only check automatically.
5. On merge, CI builds, packs, and publishes for real.

See `htop/` for a complete working example.

## `ZEXBUILD` format

A plain POSIX shell script, sourced by CI — not parsed by `substrate` or anything else. Two required functions:

```sh
pkgname=htop
pkgver=3.5.2
pkgrel=0
source="https://github.com/htop-dev/htop/releases/download/$pkgver/htop-$pkgver.tar.xz"
sha256sums="<hash>  htop-$pkgver.tar.xz"

# Runs in the extracted source tree. Produce a normal build.
build() {
    ./configure --host="$CHOST" --prefix=/overlayer/zexlib/union
    make
}

# Runs after build(). Stage installed files into $PAYLOAD_DIR — this
# becomes payload/ in the final .zex, laid out exactly as manifest.toml's
# [install] table expects (payload/bin -> [install].bin, etc.), same
# contract `substrate pack` already reads today.
package() {
    make DESTDIR="$PAYLOAD_DIR" install
}
```

| Variable | Meaning |
|---|---|
| `pkgname` | Must match `manifest.toml`'s `package.name`. |
| `pkgver` | Upstream version. |
| `pkgrel` | Recipe revision — bump on a rebuild with no upstream version change. |
| `source` | Whitespace/newline-separated list of URLs and/or local filenames (patches, install scripts) to fetch/stage before `build()`. |
| `sha256sums` | One `<hash>  <filename>` line per URL entry in `source` — CI verifies before building. |
| `$CHOST` | Set by CI to the target triple (currently `x86_64-zainium-linux-musl`). |
| `$PAYLOAD_DIR` | Set by CI to the staging directory's `payload/` — where `package()` must install to. |

Nothing about interpreter paths or install prefixes needs handling here — `substrate pack` (the last thing CI runs, after `package()`) patches ELF interpreters/RPATHs and enforces the layout policy automatically. Toolchain/self-hosting packages that are already correctly linked for the target can opt out with `native = true` in `manifest.toml`'s `[package]` table.

## `manifest.toml`

Same shape `substrate pack` has always read — see `htop/manifest.toml` for a real example, or `substrate`'s own `USAGE.md` for the full field reference.
