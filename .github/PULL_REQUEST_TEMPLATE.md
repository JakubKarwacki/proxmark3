**Describe the change**
A clear and concise description of what this PR changes and why.

**Build matrix checked**
Per `AGENTS.md`'s "Before opening a PR: build matrix" — list which axes you
actually tested, and which you deliberately skipped (say why):

- [ ] `make clean && make all` — zero compiler warnings (gcc, default toolchain)
- [ ] Second compiler (clang), if client/tools touched
- [ ] CMake build (`client/CMakeLists.txt`), kept in sync with Makefile if both touched
- [ ] ARM firmware build (`bootrom`/`armsrc`), if touched
- [ ] Ran on real hardware, if touched code path is hardware-reachable

**Related issue(s)**
Closes #

**Additional context**
Anything a reviewer needs to know that isn't obvious from the diff.
