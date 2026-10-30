Zainium OS userland recipes
===========================

Community recipes for the userland of Zainium OS: the software people
install with zex on top of the base. Fork the repository, add a recipe and
open a pull request. Once it is merged, CI builds, signs and publishes the
package, and anyone can install it:

    elevate zex install <package>

Adding a package
----------------

  1. Make a directory named after the package, with a ZEXBUILD and a
     manifest.toml. htop/ is a complete example.
  2. Put any *.patch files next to ZEXBUILD and apply them in it.
  3. Open a pull request. CI builds it to check it.

ZEXBUILD
--------

A POSIX shell script that CI sources:

    maintainer="Your Name <you@example.com>"
    pkgname=htop
    pkgver=3.5.2
    pkgrel=0
    source="https://github.com/htop-dev/htop/releases/download/$pkgver/htop-$pkgver.tar.xz"
    sha256sums="<hash>  htop-$pkgver.tar.xz"

    build() {
        ./configure --host="$CHOST" --prefix=/overlayer/syshub \
            --sysconfdir=/overlayer/syshub/etc --localstatedir=/overlayer/syshub/var
        make
    }

    package() {
        make DESTDIR="$PAYLOAD_DIR" install
    }

pkgname must match package.name in manifest.toml, and pkgrel counts
rebuilds of the same version. $CHOST is x86_64-zainium-linux-musl, and
$PAYLOAD_DIR is where package() installs. A library can add a -dev
subpackage with a dev() function and its own <name>-dev.manifest.toml.

Always build with --prefix=/overlayer/syshub, also for the userland: that
is the path every program sees, the base and the userland joined. The
manifest's _syshub = false is what puts the files in the userland. When it
packs, substrate sets each program's loader and library path, so recipes
normally need nothing more.

Rust programs build for the target in targets/x86_64-zainium-linux-musl.json.

Building
--------

GitHub Actions builds only the packages whose directory changed. A pull
request is only built. A push to main is built, packed with substrate and
published to the userland archive.

License
-------

The recipes are GPL-3.0-only (see LICENSE). The software they build keeps
its own license.
