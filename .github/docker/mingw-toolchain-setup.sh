#!/usr/bin/env bash
# Environment setup ONLY -- installs the mingw-w64/AUR toolchain and every
# target library docs/specs/mingw-cross-build.md's recipe needs. Baked into
# the ghcr.io/jakubkarwacki/proxmark3-mingw-builder image at build time (see
# .github/docker/Dockerfile), NOT run per-CI-job -- that's what makes the
# per-commit build fast (image pull + `make`, no AUR rebuild).
#
# Optimization: every mingw-w64-* AUR PKGBUILD in this ecosystem builds BOTH
# i686-w64-mingw32 and x86_64-w64-mingw32 by default (`_architectures="i686-
# w64-mingw32 x86_64-w64-mingw32"`), roughly doubling compile time for every
# source-built package -- we only ever need x86_64. For the two dominant
# time sinks (the openssl build pulled in by python312-bin, and the GD
# format-library chain: zlib/brotli/bzip2/libpng/freetype2-bootstrap/
# libjpeg-turbo/gd), that variable is patched to x86_64-only before
# `makepkg`, via build_mingw_pkg() below -- these packages are built and
# installed manually (git clone + patch + makepkg + pacman -U) instead of
# through `yay -S`, in explicit dependency order, because bypassing yay
# means losing its automatic AUR-dependency resolution.
#
# Left on plain (dual-arch) `yay -S`: mingw-w64-configure/cmake/meson
# (lightweight AUR build-tool wrappers, not worth hand-rolling), and
# lz4/readline/python312-bin (small, or with their own multi-package AUR
# dependency chains -- pdcurses/termcap/environment for readline -- not
# worth reimplementing for their share of total build time).
set -euxo pipefail

pacman -Syu --noconfirm --needed base-devel git go sudo
pacman -S --noconfirm --needed mingw-w64-gcc ccache

useradd -m builder
echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder

# Bootstrap yay (AUR helper) -- still used for the packages listed above,
# and to resolve regular (non-hand-rolled) AUR dependencies.
su builder -c '
  set -euxo pipefail
  git clone --depth 1 https://aur.archlinux.org/yay-bin.git /tmp/yay-bin
  cd /tmp/yay-bin && makepkg -si --noconfirm
'

YAY_INSTALL='yay -S --noconfirm --answerclean None --answerdiff None --mflags --noconfirm'

# AUR build-tool wrappers needed as makedepends by several packages below.
# Small, not source libraries -- left dual-arch.
su builder -c "$YAY_INSTALL mingw-w64-configure mingw-w64-cmake mingw-w64-meson mingw-w64-environment"

# build_mingw_pkg <pkg> [extra sed expression to apply to PKGBUILD] --
# clones, patches _architectures to x86_64-only (plus an optional extra
# patch, e.g. GD's ENABLE_* flags), builds, and installs via pacman -U.
# Runs as the unprivileged builder user (git clone + makepkg), except the
# final pacman -U (needs root).
build_mingw_pkg() {
  local pkg="$1"
  local extra_sed="${2:-}"
  su builder -c "
    set -euxo pipefail
    cd /home/builder
    rm -rf '$pkg'
    git clone --depth 1 'https://aur.archlinux.org/${pkg}.git'
    cd '$pkg'
    sed -i 's/_architectures=\"i686-w64-mingw32 x86_64-w64-mingw32\"/_architectures=\"x86_64-w64-mingw32\"/' PKGBUILD
    sed -i \"s/_architectures='i686-w64-mingw32 x86_64-w64-mingw32'/_architectures='x86_64-w64-mingw32'/\" PKGBUILD
    ${extra_sed}
    makepkg -sf --noconfirm
  "
  pacman -U --noconfirm /home/builder/"$pkg"/"$pkg"-*.pkg.tar.zst
}

# --- x86_64-only manual builds, in dependency order ---

# T2 -- bzip2 (needed both directly by client/Makefile, R2, and as a
# freetype2-bootstrap dependency below).
build_mingw_pkg mingw-w64-bzip2

# T8 GD chain: zlib -> brotli (freetype2-bootstrap's AUR dep) ->
# libpng/freetype2-bootstrap/libjpeg-turbo -> gd.
build_mingw_pkg mingw-w64-zlib
build_mingw_pkg mingw-w64-brotli
build_mingw_pkg mingw-w64-libpng
build_mingw_pkg mingw-w64-freetype2-bootstrap
build_mingw_pkg mingw-w64-libjpeg-turbo

# mingw-w64-gd (AUR) builds with every image-format flag OFF by default (its
# PKGBUILD passes no -D flags to CMake, and libgd defaults
# ENABLE_PNG/JPEG/FREETYPE/GD_FORMATS to 0) -- patch it to match libgd's own
# upstream mingw CI recipe (.github/workflows/ci_windows_mingw.yml upstream),
# on top of the x86_64-only patch every build_mingw_pkg call already applies.
build_mingw_pkg mingw-w64-gd \
  'sed -i "s#\${_arch}-cmake -B build-\${_arch} \.#\${_arch}-cmake -B build-\${_arch} . -DENABLE_GD_FORMATS=1 -DENABLE_PNG=1 -DENABLE_JPEG=1 -DENABLE_FREETYPE=1#" PKGBUILD'

# T7 -- openssl (python312-bin's real dependency; building it x86_64-only
# here means `yay -S mingw-w64-python312-bin` below sees it already
# satisfied and skips building it itself).
build_mingw_pkg mingw-w64-openssl

# --- remaining packages: small / complex AUR dep chains, left on yay -S ---

# T3/T4 -- lz4, readline
su builder -c "$YAY_INSTALL mingw-w64-lz4 mingw-w64-readline"

# T7 -- python-embed (openssl dependency already satisfied above)
su builder -c "$YAY_INSTALL mingw-w64-python312-bin"

# T7: mingw-w64-python312-bin ships no pkg-config file (verified in this
# repo, docs/specs/mingw-cross-build.md T7) -- write one so client/Makefile's
# default PYTHON3_PKGCONFIG=python3 probe for "python3-embed" resolves.
mkdir -p /usr/x86_64-w64-mingw32/lib/pkgconfig
cat > /usr/x86_64-w64-mingw32/lib/pkgconfig/python3-embed.pc <<'PC'
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

# Slim the image: drop makepkg source/build trees and pacman's own package
# cache (everything needed at link time is already installed under
# /usr/x86_64-w64-mingw32/ and /usr/bin -- these are just leftover build
# artifacts).
rm -rf /tmp/yay-bin /home/builder/mingw-w64-*
pacman -Scc --noconfirm
