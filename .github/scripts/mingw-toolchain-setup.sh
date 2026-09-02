#!/usr/bin/env bash
# Provisions the mingw-w64/AUR cross-compile toolchain DIRECTLY on this
# self-hosted runner host (Arch Linux) -- no Docker. Idempotent-ish: safe
# to re-run, but does not skip already-built AUR packages (they're rebuilt
# from source every time this runs; it's meant to run rarely, only when
# this script itself or the target package list changes -- see
# .github/workflows/mingw-toolchain-setup.yml).
#
# Every mingw-w64-* AUR PKGBUILD in this ecosystem builds BOTH
# i686-w64-mingw32 and x86_64-w64-mingw32 by default -- we only ever need
# x86_64. For the two dominant time sinks (openssl, pulled in by
# python312-bin, and the GD chain: zlib/brotli/bzip2/libpng/
# freetype2-bootstrap/libjpeg-turbo/gd), that variable is patched to
# x86_64-only before makepkg via build_mingw_pkg() below.
#
# See docs/specs/mingw-cross-build.md for the full research/rationale.
set -euxo pipefail

SUDO="sudo"
if [ -n "${SUDO_ASKPASS:-}" ]; then
  SUDO="sudo -A"
fi

$SUDO pacman -Sy --noconfirm --needed base-devel git go mingw-w64-gcc ccache

if ! command -v yay >/dev/null 2>&1; then
  tmpdir="$(mktemp -d)"
  git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$tmpdir/yay-bin"
  (cd "$tmpdir/yay-bin" && makepkg -si --noconfirm --skippgpcheck)
  rm -rf "$tmpdir"
fi

YAY_INSTALL='yay -S --noconfirm --answerclean None --answerdiff None --mflags "--skippgpcheck"'

# AUR build-tool wrappers needed as makedepends by several packages below.
eval "$YAY_INSTALL mingw-w64-configure mingw-w64-cmake mingw-w64-meson mingw-w64-environment"

# build_mingw_pkg <pkg> -- clones, patches _architectures to x86_64-only,
# builds, and installs via `sudo pacman -U`.
build_mingw_pkg() {
  local pkg="$1"
  local workdir
  workdir="$(mktemp -d)"
  git clone --depth 1 "https://aur.archlinux.org/${pkg}.git" "$workdir/$pkg"
  cd "$workdir/$pkg"

  sed -i 's/_architectures="i686-w64-mingw32 x86_64-w64-mingw32"/_architectures="x86_64-w64-mingw32"/' PKGBUILD
  sed -i "s/_architectures='i686-w64-mingw32 x86_64-w64-mingw32'/_architectures='x86_64-w64-mingw32'/" PKGBUILD

  if [ "$pkg" = "mingw-w64-gd" ]; then
    # libgd defaults every image-format flag OFF; match its own upstream
    # mingw CI recipe.
    sed -i 's#${_arch}-cmake -B build-${_arch} \.#${_arch}-cmake -B build-${_arch} . -DENABLE_GD_FORMATS=1 -DENABLE_PNG=1 -DENABLE_JPEG=1 -DENABLE_FREETYPE=1#' PKGBUILD
  fi

  makepkg -sf --noconfirm --skippgpcheck
  $SUDO pacman -U --noconfirm ./"${pkg}"-*.pkg.tar.zst
  cd /
  rm -rf "$workdir"
}

# T2 -- bzip2. T8 GD chain, in dependency order: zlib -> brotli ->
# libpng/freetype2-bootstrap/libjpeg-turbo -> gd. T7 -- openssl.
build_mingw_pkg mingw-w64-bzip2
build_mingw_pkg mingw-w64-zlib
build_mingw_pkg mingw-w64-brotli
build_mingw_pkg mingw-w64-libpng
build_mingw_pkg mingw-w64-freetype2-bootstrap
build_mingw_pkg mingw-w64-libjpeg-turbo
build_mingw_pkg mingw-w64-gd
build_mingw_pkg mingw-w64-openssl

# T3/T4/T7 -- small / complex-AUR-dep-chain packages left on plain yay -S.
eval "$YAY_INSTALL mingw-w64-lz4 mingw-w64-readline"
eval "$YAY_INSTALL mingw-w64-python312-bin"

# T7: mingw-w64-python312-bin ships no pkg-config file (verified in this
# repo, docs/specs/mingw-cross-build.md T7) -- install one so client/Makefile's
# default PYTHON3_PKGCONFIG=python3 probe for "python3-embed" resolves.
$SUDO mkdir -p /usr/x86_64-w64-mingw32/lib/pkgconfig
cat <<'PC' | $SUDO tee /usr/x86_64-w64-mingw32/lib/pkgconfig/python3-embed.pc >/dev/null
prefix=/usr/x86_64-w64-mingw32
exec_prefix=${prefix}
includedir=${prefix}/include/python312
libdir=${prefix}/lib

Name: Python
Description: Embed Python into an application (mingw-w64 x86_64-w64-mingw32 cross build, CPython 3.12 embeddable distribution)
Version: 3.12.10
Cflags: -I${includedir}
Libs: -L${libdir} -lpython312
PC
