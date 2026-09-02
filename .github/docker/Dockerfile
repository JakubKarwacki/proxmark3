# Prebuilt mingw-w64/AUR toolchain image for cross-building client/proxmark3.exe.
# Published to ghcr.io/jakubkarwacki/proxmark3-mingw-builder by
# .github/workflows/mingw-builder-image.yml whenever this file or
# mingw-toolchain-setup.sh changes. CI jobs (mingw-cross.yml, and
# pm3-connector's release.yml) pull this image and just run `make` against
# it -- the ~30-45min AUR build (bzip2/lz4/readline/python-embed/the GD
# chain, see docs/specs/mingw-cross-build.md) happens ONCE here, not on
# every commit/release.
FROM archlinux:latest

COPY mingw-toolchain-setup.sh /tmp/mingw-toolchain-setup.sh
RUN bash /tmp/mingw-toolchain-setup.sh && rm /tmp/mingw-toolchain-setup.sh
