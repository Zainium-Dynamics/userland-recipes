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
source="https://github.com/htop-dev/htop/releases/download/$pkgver/htop-$pkgver.tar.xz"
sha256sums="<hash>  htop-$pkgver.tar.xz"

# Runs in the extracted source tree. Produce a normal build. See "Why
# --prefix=/overlayer/syshub" below — this is correct even though the
# package itself is userland (_syshub = false in manifest.toml).
build() {
    ./configure \
        --host="$CHOST" \
        --prefix=/overlayer/syshub \
        --sysconfdir=/overlayer/syshub/etc \
        --mandir=/overlayer/syshub/share/man \
        --infodir=/overlayer/syshub/share/info \
        --localstatedir=/overlayer/syshub/var
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
| `maintainer` | Who maintains *this recipe* (not necessarily upstream) — `Name <email>`, same convention as Alpine's APKBUILD. |
| `pkgname` | Must match `manifest.toml`'s `package.name`. |
| `pkgver` | Upstream version. |
| `pkgrel` | Recipe revision — bump on a rebuild with no upstream version change. |
| `subpackages` | Optional, space-separated. **Only a `-dev` split is a thing here** — no `-doc`/`-doc`-style subpackages. Use it for a *library* package that ships headers/static libs/`.so` symlinks a `-dev` package would carry, not for splitting out man pages/docs. |
| `source` | Whitespace/newline-separated list of URLs and/or local filenames (patches, install scripts) to fetch/stage before `build()`. |
| `sha256sums` | One `<hash>  <filename>` line per URL entry in `source` — CI verifies before building. |
| `$CHOST` | Set by CI to the target triple (currently `x86_64-zainium-linux-musl`). |
| `$PAYLOAD_DIR` | Set by CI to the main package's staging `payload/`. |
| `$SUBPKG_PAYLOAD_DIR` | Set by CI, only for the `-dev` subpackage function call, to its own staging `payload/`. |

`htop` above has no meaningful `-dev` split (it's an end-user binary, no library to build against), so it doesn't use `subpackages` at all. A library package would:

```sh
pkgname=libfoo
subpackages="$pkgname-dev"

package() {
    make DESTDIR="$PAYLOAD_DIR" install
}

# CI runs this after package() — move headers/.so-symlinks/pkgconfig
# files OUT of $PAYLOAD_DIR into $SUBPKG_PAYLOAD_DIR, matching a
# libfoo-dev.manifest.toml next to the main manifest.toml. Two .zex
# outputs from one recipe: libfoo (runtime .so) and libfoo-dev (headers).
dev() {
    mkdir -p "$SUBPKG_PAYLOAD_DIR"/include "$SUBPKG_PAYLOAD_DIR"/lib
    mv "$PAYLOAD_DIR"/include/* "$SUBPKG_PAYLOAD_DIR"/include/
    mv "$PAYLOAD_DIR"/lib/*.a "$PAYLOAD_DIR"/lib/*.so "$SUBPKG_PAYLOAD_DIR"/lib/ 2>/dev/null || true
}
```

Nothing about interpreter paths or install prefixes needs patching by hand here — `substrate pack` (the last thing CI runs, once per package *and* once per subpackage, after `package()`/the subpackage functions) patches ELF interpreters/RPATHs and enforces the layout policy automatically. Toolchain/self-hosting packages that are already correctly linked for the target can opt out with `native = true` in `manifest.toml`'s `[package]` table.

### Why `--prefix=/overlayer/syshub` even for userland packages

Zainium's root is an OverlayFS: `/overlayer/syshub` is the **lowerdir** (the immutable base OS) and `/overlayer/zexlib/union` is the **upperdir** (where userland packages actually get written to disk). Once mounted, the two merge into one filesystem view — and the path that view is mounted at is `/overlayer/syshub`. A running program never sees `/overlayer/zexlib/union` at all; it only ever sees the merged result at `/overlayer/syshub`, regardless of which layer a given file physically lives on.

That means whatever path gets baked into a binary at build time (via `--prefix`/`--sysconfdir`/`--mandir`/`--infodir`/`--localstatedir` — anything the build system compiles in for the program to find its own files later) has to be the **runtime-visible merged path**, `/overlayer/syshub`, even for a userland package. This is separate from `manifest.toml`'s `_syshub` flag, which stays `false` for userland packages — that flag tells `substrate`/the installer which physical layer to *write* the files to (and drives its own RPATH computation), not what path the program itself was built expecting.

### The dynamic linker (interpreter) path

Every dynamically-linked ELF binary's `PT_INTERP` — the loader the kernel runs first — is:

```
/overlayer/syshub/x86_64-zainium-linux-musl/lib/ld-musl-x86_64.so.1
```

Always this, regardless of `_syshub`, same reasoning as above: the loader is one shared system component every binary needs to find at the same runtime-visible path. You don't need to set this yourself — `substrate pack` patches every payload binary's interpreter to this automatically (`elfpatch.rs`). It's documented here so it's not a mystery if you ever inspect a built binary directly (`readelf -l` / `patchelf --print-interpreter`).

### Rust packages — target spec

`targets/x86_64-zainium-linux-musl.json` in this repo is the custom Rust target spec for Zainium's musl userland (matches the one `substrate`/`zex-server` build against). A Rust `ZEXBUILD` should build against it explicitly, not the host's default target:

```sh
build() {
    cargo build --release --target="$RECIPE_ROOT/../targets/x86_64-zainium-linux-musl.json"
}

package() {
    install -Dm755 target/x86_64-zainium-linux-musl/release/"$pkgname" "$PAYLOAD_DIR"/bin/"$pkgname"
}
```

(Exact `$RECIPE_ROOT`-style variable name TBD once CI actually sets it up for Rust builds — not wired yet, this documents the intent.)

## `manifest.toml`

Same shape `substrate pack` has always read — see `htop/manifest.toml` for a real example, or `substrate`'s own `USAGE.md` for the full field reference. A `-dev` subpackage's `manifest.toml` is a completely normal one — `package.name` is the subpackage's own name (e.g. `libfoo-dev`), not the parent's.

## A note on CI time

There's no self-hosted runner behind this yet — builds run on GitLab.com's shared runners, so they're bound by its free-tier CI minutes and per-job timeout. Keep `ZEXBUILD`s lean (avoid unnecessary rebuild-the-world steps, prefer upstream's own incremental build where possible) — a recipe that reliably blows past the shared-runner timeout needs to shrink its build, not get a special exception.

## CI/CD variables (project settings, protected + masked)

| Variable | Meaning |
|---|---|
| `SUBSTRATE_BINARY_URL` | Where CI fetches a prebuilt `substrate` binary from. |
| `ZEX_PORTS_BINARY_URL` | Where CI fetches a prebuilt `zex-ports` binary from (the tool that uploads a built `.zex` to R2 and merges it into the ledger — only needed on `main`, not on MR check builds). |
| `R2_ENDPOINT` | `https://<account_id>.r2.cloudflarestorage.com` |
| `R2_BUCKET` | The R2 bucket packages publish to. |
| `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | R2 API token (S3-compatible credentials) — publish-only scope, not full account access. |
| `REQUIRES_SYSHUB` | Passed straight to `substrate pack --requires-syshub`. |
