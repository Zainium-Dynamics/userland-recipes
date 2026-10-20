# userland-recipes

Community package recipes for the userland of Zainium OS, an immutable Linux distribution built on musl.

Fork the repo, add a recipe and open a pull request. Once it is merged, CI builds the package, packs it with [substrate](https://crates.io/crates/substrate-zainium) and publishes it to the package repository. A `ZEXBUILD` plays the role an `APKBUILD` plays in Alpine's aports.

## Adding a package

1. Fork this repo.
2. Create `<pkgname>/ZEXBUILD` and `<pkgname>/manifest.toml`. See `htop/` for a complete example.
3. Put any `*.patch` files next to `ZEXBUILD` and apply them inside it.
4. Open a pull request. CI runs a build-only check.
5. After the merge, CI builds and publishes the package.

## ZEXBUILD

A POSIX shell script sourced by CI.

```sh
maintainer="Your Name <you@example.com>"
pkgname=htop
pkgver=3.5.2
pkgrel=0
source="https://github.com/htop-dev/htop/releases/download/$pkgver/htop-$pkgver.tar.xz"
sha256sums="<hash>  htop-$pkgver.tar.xz"

build() {
    ./configure \
        --host="$CHOST" \
        --prefix=/overlayer/syshub \
        --sysconfdir=/overlayer/syshub/etc \
        --localstatedir=/overlayer/syshub/var
    make
}

package() {
    make DESTDIR="$PAYLOAD_DIR" install
}
```

- `maintainer`: who maintains the recipe, as `Name <email>`.
- `pkgname`: must match `package.name` in `manifest.toml`.
- `pkgver`, `pkgrel`: upstream version and recipe revision.
- `subpackages`: optional. Only a `-dev` split is supported.
- `source`, `sha256sums`: URLs and local files to fetch, and a checksum line per URL.
- `$CHOST`: target triple, `x86_64-zainium-linux-musl`.
- `$PAYLOAD_DIR`: staging directory of the package.
- `$SUBPKG_PAYLOAD_DIR`: staging directory of the `-dev` subpackage.

A library can ship a `-dev` package with a `dev()` function that moves headers, `.a` files and `.so` symlinks into `$SUBPKG_PAYLOAD_DIR`. It needs a matching `<name>-dev.manifest.toml`.

`substrate pack` patches ELF interpreters and RPATHs and enforces the layout policy after `package()`. Packages that are already linked for the target can set `native = true` in `manifest.toml` to skip this.

## Install prefix

Always build with `--prefix=/overlayer/syshub`, even for userland packages.

`/overlayer/syshub` is the merged view of the immutable base and the userland layer, so it is the only path a running program ever sees. The `_syshub = false` flag in `manifest.toml` only decides which layer the files are written to.

Every binary uses `/overlayer/syshub/x86_64-zainium-linux-musl/lib/ld-musl-x86_64.so.1` as its interpreter. `substrate pack` sets it, so recipes normally do nothing. For Makefile-only builds, you can set it yourself:

```make
BASIC_LDFLAGS += -Wl,-dynamic-linker,/overlayer/syshub/x86_64-zainium-linux-musl/lib/ld-musl-x86_64.so.1
BASIC_LDFLAGS += -Wl,-rpath,/overlayer/syshub/lib
```

## Rust packages

`targets/x86_64-zainium-linux-musl.json` is the custom Rust target for Zainium's musl userland. Build against it instead of the host target.

## manifest.toml

The same format `substrate pack` has always read. See `htop/manifest.toml`. A `-dev` subpackage has its own manifest whose `package.name` is the subpackage name.

## CI

GitHub Actions workflow `.github/workflows/ci.yml` has two jobs:

- `check` runs on every pull request and only builds.
- `release` runs on every push to `main`, then builds and publishes.

Only packages whose directory changed are built.

## License

The recipes in this repository are licensed under GPL-3.0-only. See `LICENSE`. Upstream software keeps its own license.
