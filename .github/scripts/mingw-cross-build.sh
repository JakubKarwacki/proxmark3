#!/usr/bin/env bash
# Runs INSIDE an archlinux:latest container with the repo bind-mounted at
# /repo and /var/cache/pacman/pkg bind-mounted to a host cache dir.
# See docs/specs/mingw-cross-build.md (T1-T10) and
# .github/workflows/mingw-cross.yml (T11) for context.
set -euxo pipefail

pacman -Syu --noconfirm --needed base-devel git go sudo
pacman -S --noconfirm --needed mingw-w64-gcc

useradd -m builder
echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder

# Bootstrap yay (AUR helper) -- needed for automatic AUR dependency
# resolution (readline pulls in pdcurses/termcap/environment/pkg-config/
# configure transitively; python-bin pulls in openssl; the GD chain pulls
# in brotli via freetype2-bootstrap).
su builder -c '
  set -euxo pipefail
  git clone --depth 1 https://aur.archlinux.org/yay-bin.git /tmp/yay-bin
  cd /tmp/yay-bin && makepkg -si --noconfirm
'

YAY_INSTALL='yay -S --noconfirm --answerclean None --answerdiff None --mflags --noconfirm'

# T2/T3/T4/T7 -- bzip2, lz4, readline, python
su builder -c "$YAY_INSTALL mingw-w64-bzip2 mingw-w64-lz4 mingw-w64-readline"
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

# T8: GD chain, in dependency order. freetype2-bootstrap (not plain
# freetype2) avoids a real circular freetype2<->harfbuzz AUR dependency that
# fans out into building a Rust compiler from source (see
# docs/specs/mingw-cross-build.md research notes).
su builder -c "$YAY_INSTALL mingw-w64-zlib"
su builder -c "$YAY_INSTALL mingw-w64-libpng mingw-w64-freetype2-bootstrap mingw-w64-libjpeg-turbo"

# mingw-w64-gd (AUR) builds with every image-format flag OFF by default (its
# PKGBUILD passes no -D flags to CMake, and libgd defaults
# ENABLE_PNG/JPEG/FREETYPE/GD_FORMATS to 0) -- patch it to match libgd's own
# upstream mingw CI recipe (.github/workflows/ci_windows_mingw.yml upstream).
su builder -c '
  set -euxo pipefail
  cd /home/builder
  rm -rf mingw-w64-gd
  git clone --depth 1 https://aur.archlinux.org/mingw-w64-gd.git
  cd mingw-w64-gd
  sed -i "s#\${_arch}-cmake -B build-\${_arch} \.#\${_arch}-cmake -B build-\${_arch} . -DENABLE_GD_FORMATS=1 -DENABLE_PNG=1 -DENABLE_JPEG=1 -DENABLE_FREETYPE=1#" PKGBUILD
  makepkg -f --noconfirm
'
pacman -U --noconfirm /home/builder/mingw-w64-gd/mingw-w64-gd-*.pkg.tar.zst

# T9: integration build.
cd /repo
make clean
make CROSS_MINGW=1 SKIPBT=1 SKIPQT=1 SKIPREVENGTEST=1 client

# Stage runtime DLLs the produced exe genuinely needs (R3/T10 packaging)
# next to it, inside the bind-mounted workspace, so the host-side Wine
# smoke test step (outside this container) can find them.
cd /repo/client
for f in libgd libssp-0 libstdc++-6 libfreetype-6 libjpeg-8 libpng16-16 zlib1 python312 \
         libgcc_s_seh-1 libwinpthread-1 libbrotlidec libbrotlicommon libbz2-1; do
  cp "/usr/x86_64-w64-mingw32/bin/${f}.dll" .
done
