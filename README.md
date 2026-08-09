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
maintainer="Your Name <you@example.com>"
pkgname=htop
pkgver=3.5.2
pkgrel=0
subpackages="$pkgname-doc"
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

# One function per name listed in $subpackages (Alpine's exact
# convention). Runs after package() — move files that belong in the
# subpackage OUT of $PAYLOAD_DIR and into $SUBPKG_PAYLOAD_DIR instead.
# CI then runs `substrate pack` twice: once for $PAYLOAD_DIR against
# manifest.toml, once for $SUBPKG_PAYLOAD_DIR against
# <pkgname>-doc.manifest.toml — two independent .zex outputs from one
# recipe.
doc() {
    mkdir -p "$SUBPKG_PAYLOAD_DIR"/share/man
    mv "$PAYLOAD_DIR"/share/man/* "$SUBPKG_PAYLOAD_DIR"/share/man/
}
```

| Variable | Meaning |
|---|---|
| `maintainer` | Who maintains *this recipe* (not necessarily upstream) — `Name <email>`, same convention as Alpine's APKBUILD. |
| `pkgname` | Must match `manifest.toml`'s `package.name`. |
| `pkgver` | Upstream version. |
| `pkgrel` | Recipe revision — bump on a rebuild with no upstream version change. |
| `subpackages` | Optional, space-separated. For each name, CI expects a matching shell function (see `doc()` above) and a matching `<name>.manifest.toml` next to the main `manifest.toml`. |
| `source` | Whitespace/newline-separated list of URLs and/or local filenames (patches, install scripts) to fetch/stage before `build()`. |
| `sha256sums` | One `<hash>  <filename>` line per URL entry in `source` — CI verifies before building. |
| `$CHOST` | Set by CI to the target triple (currently `x86_64-zainium-linux-musl`). |
| `$PAYLOAD_DIR` | Set by CI to the main package's staging `payload/`. |
| `$SUBPKG_PAYLOAD_DIR` | Set by CI, per subpackage function call, to that subpackage's own staging `payload/`. |

Nothing about interpreter paths or install prefixes needs handling here — `substrate pack` (the last thing CI runs, once per package *and* once per subpackage, after `package()`/the subpackage functions) patches ELF interpreters/RPATHs and enforces the layout policy automatically. Toolchain/self-hosting packages that are already correctly linked for the target can opt out with `native = true` in `manifest.toml`'s `[package]` table.

## `manifest.toml`

Same shape `substrate pack` has always read — see `htop/manifest.toml` for a real example (and `htop/htop-doc.manifest.toml` for a subpackage one), or `substrate`'s own `USAGE.md` for the full field reference. A subpackage's `manifest.toml` is a completely normal one — `package.name` is the subpackage's own name (e.g. `htop-doc`), not the parent's.

## A note on CI time

There's no self-hosted runner behind this yet — builds run on GitLab.com's shared runners, so they're bound by its free-tier CI minutes and per-job timeout. Keep `ZEXBUILD`s lean (avoid unnecessary rebuild-the-world steps, prefer upstream's own incremental build where possible) — a recipe that reliably blows past the shared-runner timeout needs to shrink its build, not get a special exception.
