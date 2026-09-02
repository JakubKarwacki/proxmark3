#!/usr/bin/env bash
# Runs DIRECTLY on the self-hosted runner host (no Docker) -- the mingw-w64/
# AUR toolchain is provisioned once, ahead of time, on this same machine by
# .github/scripts/mingw-toolchain-setup.sh (see
# .github/workflows/mingw-toolchain-setup.yml). This script only does the
# actual build (T9) + runtime DLL staging (T10 packaging).
# See docs/specs/mingw-cross-build.md and .github/workflows/mingw-cross.yml.
set -euxo pipefail

cd "$(dirname "$0")/../.."

export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/mingw-cross-ccache}"
mkdir -p "$CCACHE_DIR"
ccache --max-size=2G >/dev/null

make clean
make CROSS_MINGW=1 SKIPBT=1 SKIPQT=1 SKIPREVENGTEST=1 \
     CC='ccache x86_64-w64-mingw32-gcc' CXX='ccache x86_64-w64-mingw32-g++' \
     client

ccache -s

# Stage runtime DLLs the produced exe genuinely needs (R3/T10 packaging)
# next to it, so the Wine smoke test step can find them.
cd client
for f in libgd libssp-0 libstdc++-6 libfreetype-6 libjpeg-8 libpng16-16 zlib1 python312 \
         libgcc_s_seh-1 libwinpthread-1 libbrotlidec libbrotlicommon libbz2-1; do
  cp "/usr/x86_64-w64-mingw32/bin/${f}.dll" .
done
