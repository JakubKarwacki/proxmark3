#!/usr/bin/env bash
# Runs INSIDE the prebuilt ghcr.io/jakubkarwacki/proxmark3-mingw-builder
# image (.github/docker/Dockerfile), with the repo bind-mounted at /repo.
# Toolchain + every target library (bzip2/lz4/readline/Lua/Jansson/
# Python-embed/GD chain) is already installed in the image -- this script
# only does the actual build (T9) + runtime DLL staging (T10 packaging).
# See docs/specs/mingw-cross-build.md and .github/workflows/mingw-cross.yml.
set -euxo pipefail

cd /repo
make clean
make CROSS_MINGW=1 SKIPBT=1 SKIPQT=1 SKIPREVENGTEST=1 client

# Stage runtime DLLs the produced exe genuinely needs (R3/T10 packaging)
# next to it, inside the bind-mounted workspace, so a host-side Wine smoke
# test (outside this container) can find them.
cd /repo/client
for f in libgd libssp-0 libstdc++-6 libfreetype-6 libjpeg-8 libpng16-16 zlib1 python312 \
         libgcc_s_seh-1 libwinpthread-1 libbrotlidec libbrotlicommon libbz2-1; do
  cp "/usr/x86_64-w64-mingw32/bin/${f}.dll" .
done
