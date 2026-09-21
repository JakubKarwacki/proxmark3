# Spec: Cross-kompilacja klienta `proxmark3.exe` przez mingw-w64 z Linuksa

---
verified: 2026-09-21
verified_by: "bash .github/scripts/mingw-cross-build.sh && wine client/proxmark3.exe -v"
reverify: "cd /data/projects/proxmark3 && bash .github/scripts/mingw-cross-build.sh && wine client/proxmark3.exe --help"
status: zaimplementowane, przetestowane i zweryfikowane w CI/CD
---

## 1. Kontekst i problem inżynieryjny

Historycznie upstreamowy projekt `RfidResearchGroup/proxmark3` posiadał wyłącznie jedną oficjalną ścieżkę budowania klienta hosta (`client/proxmark3.exe`) dla systemu Windows: **natywny build w środowisku ProxSpace / MSYS2 pod kontrolą systemu Windows**.

### Wady podejścia ProxSpace / MSYS2
1. **Wymóg środowiska Windows / VM**: Wymagało fizycznej maszyny z Windows lub powolnych runnerów wirtualnych (`windows-latest` w GitHub Actions).
2. **Drastyczny narzut czasowy w CI**: Pobranie środowiska ProxSpace, rozpakowanie wielogigabajtowego archiwum i kompilacja w MSYS2 trwały w GitHub Actions **od 35 do 40 minut** na pojedynczy build (potwierdzone m.in. w workflow `windows.yml` i repozytoriach powiązanych).
3. **Warstwa emulacji POSIX**: Kompilacja pod MSYS2 na Windowsie jest obarczona narzutem translacji ścieżek, powolnego forkowania procesów (`fork()` na Windows NT) oraz niestabilnościami cache'owania.
4. **Brak wsparcia w upstream**: System budowania upstreamu opierał się na detekcji `uname` (`Makefile.defs`), przez co kompilacja dla Windows z poziomu Linuksa nie była wspierana.

### Cel projektu
Umożliwienie **pełnej, deterministycznej cross-kompilacji** klienta `client/proxmark3.exe` (format PE32+ x86_64) bezpośrednio ze środowiska **Linux (Arch Linux)** przy użyciu toolchaina `mingw-w64`, **bez dotykania środowiska Windows, ProxSpace ani MSYS2**.

Kluczowe założenia:
- **Pełny parytet funkcjonalny**: obsługa Readline, zintegrowanego Lua (vendored), formatu Jansson (vendored), wbudowanego interpretera Python 3.12 (`python3-embed`) oraz pełnej obsługi biblioteki graficznej GD (`libgd` z formatami PNG, JPEG i FreeType dla podglądu zdjęć biometrycznych eMRTD/DG2).
- **Maksymalnie statyczny runtime**: wyeliminowanie konieczności instalowania bibliotek MinGW na maszynie docelowej. Runtime kompilatora (`libgcc`, `libstdc++`, `winpthread`) linkowany jest statycznie.
- **Błyskawiczny czas budowy**: dzięki natywnemu kompilatorowi Linuksa i `ccache` czas pełnej kompilacji skrócony z ~37 minut do **poniżej 15 sekund**.
- **Niezależność firmware**: moduły `bootrom` i `armsrc` (firmware mikrokontrolera ARM) kompilowane są osobnym toolchainem `arm-none-eabi-gcc` i pozostają w 100% niezależne od tego zadania.

---

## 2. Architektura rozwiązania

### 2.1. Przełącznik `CROSS_MINGW=1` w `Makefile.defs`
Aby nie łamać kompatybilności z upstreamem, cała logika cross-kompilacji została zamknięta pod flagą `CROSS_MINGW=1`:

```makefile
ifeq ($(CROSS_MINGW),1)
    MINGW_TRIPLE ?= x86_64-w64-mingw32
    MINGW_SYSROOT ?= /usr/$(MINGW_TRIPLE)
    IS_WINDOWS := 1
    IS_MINGW := 1
    CC := $(MINGW_TRIPLE)-gcc
    CXX := $(MINGW_TRIPLE)-g++
    AR := $(MINGW_TRIPLE)-ar rcs
    RANLIB := $(MINGW_TRIPLE)-ranlib
    PKG_CONFIG_ENV := PKG_CONFIG_LIBDIR=$(MINGW_SYSROOT)/lib/pkgconfig PKG_CONFIG_PATH=
endif
```

#### Hermetyzacja wyszukiwania pakietów (`PKG_CONFIG_ENV`) — Wymóg R2
Krytycznym problemem przy cross-kompilacji jest wyciek nagłówków i definicji linkerów z systemu hosta. Domyślne wywołanie `pkg-config` na Linuksie odczytuje ścieżki `/usr/lib/pkgconfig` (pliki ELF x86_64-linux). 
Rozwiązanie: nadpisanie `PKG_CONFIG_LIBDIR=$(MINGW_SYSROOT)/lib/pkgconfig` oraz wyczyszczenie `PKG_CONFIG_PATH=` gwarantuje, że linker widzi wyłącznie biblioteki przygotowane dla sysrootu MinGW.

### 2.2. Flagi linkera i zarządzanie symbolami — Wymóg R7

W `Makefile.defs` pod gałęzią `CROSS_MINGW=1` zdefiniowano zestaw flag:

1. **Statyczny runtime MinGW**:
   `-static -static-libgcc -static-libstdc++`
2. **Priorytet bibliotek statycznych (`-Wl,-Bstatic`)**:
   GNU `ld` domyślnie preferuje biblioteki importowe `.dll.a` nad statycznymi `.a`. Wiele pakietów AUR instaluje oba warianty (np. `bzip2`, `lz4`, `readline`, `zlib`). Wymuszenie `-Wl,-Bstatic` sprawia, że linker dołącza kod bezpośrednio do pliku `.exe`.
3. **Rozwiązanie konfliktu symbolu `PC` (`-Wl,--allow-multiple-definition`)**:
   Biblioteki `libreadline.a` i `libtermcap.a` definiują globalną zmienną bufora opóźniającego `PC`. Od GCC 10 domyślna flaga `-fno-common` traktuje podwójną definicję zmiennej globalnej jako błąd krytyczny linkera. Dodanie flagi `--allow-multiple-definition` rozwiązuje ten konflikt.

### 2.3. Dynamiczne wyjątki w `client/Makefile`
Dwie biblioteki w ekosystemie MinGW nie posiadają wariantów statycznych `.a` w dystrybucjach Arch/AUR:
- `libgd.dll` (AUR `mingw-w64-gd` buduje wyłącznie bibliotekę współdzieloną).
- `python312.dll` (oficjalna dystrybucja embeddable CPython od python.org).

W `client/Makefile` zastosowano precyzyjne nawiasowanie linkera, które tymczasowo przełącza tryb na dynamiczny tylko dla tych dwóch bibliotek:
```makefile
ifdef IS_MINGW
    LDLIBS += -Wl,-Bdynamic $(PYTHONLIBLD) -Wl,-Bstatic
endif

ifdef IS_MINGW
    LDLIBS += -Wl,-Bdynamic $(GDLDLIBS) -Wl,-Bstatic
endif
```
Dla biblioteki Readline dodano jawne dołączenie zależności statycznych:
```makefile
ifdef IS_MINGW
    LDLIBS += -lhistory -ltermcap
endif
```

### 2.4. Ekstrakcja Microsoft Visual C++ Runtime (`VCRUNTIME140.dll`)
`mingw-w64-python312-bin` dostarcza oficjalną binarkę CPython zbudowaną przy użyciu Microsoft Visual C++ (MSVC). Wymaga ona obecności biblioteki `vcruntime140.dll`. 
- **Problem**: Test dymny pod Wine przechodził poprawnie, ponieważ Wine dostarcza wbudowany stub `vcruntime140.dll`. Na "czystym" systemie Windows bez zainstalowanego pakietu VC++ Redistributable uruchomienie `proxmark3.exe` kończyło się błędem brakującej biblioteki.
- **Rozwiązanie**: W skrypcie `.github/scripts/mingw-toolchain-setup.sh` zaimplementowano automatyczny mechanizm pobierania oficjalnego instalatora Microsoft `vc_redist.x64.exe`, carving drugiego archiwum CAB (`MSCF`) i ekstrakcję oryginalnego pliku `vcruntime140.dll` bezpośrednio do sysrootu `/usr/x86_64-w64-mingw32/bin/`.

---

## 3. Kompletny zestaw bibliotek dystrybucyjnych (Staging DLL)

Podczas budowy paczki wydaniowej skrypt `.github/scripts/mingw-cross-build.sh` umieszcza obok `proxmark3.exe` dokładnie 14 bibliotek DLL:

| Plik DLL | Rola / Przeznaczenie | Typ / Pochodzenie |
|---|---|---|
| `proxmark3.exe` | Główny plik wykonywalny klienta Proxmark3 | PE32+ (x86_64 console executable) |
| `libgd.dll` | Renderowanie obrazów biometrycznych (DG2/eMRTD) | Dynamiczny wyjątek (AUR `mingw-w64-gd`) |
| `python312.dll` | Wbudowane środowisko uruchomieniowe Python 3.12 | Dynamiczny wyjątek (CPython embeddable) |
| `vcruntime140.dll` | Runtime Microsoft VC++ wymagany przez `python312.dll` | Oryginalny plik Microsoft VC++ 2015-2022 |
| `libpng16-16.dll` | Obsługa formatu graficznego PNG | Zależność `libgd.dll` |
| `libjpeg-8.dll` | Obsługa formatu graficznego JPEG | Zależność `libgd.dll` |
| `libfreetype-6.dll` | Obsługa czcionek i wektorów tekstowych | Zależność `libgd.dll` |
| `zlib1.dll` | Biblioteka kompresji | Zależność `libpng` oraz `libgd` |
| `libbrotlidec.dll` | Dekompresor Brotli | Zależność `libfreetype` |
| `libbrotlicommon.dll` | Wspólne struktury Brotli | Zależność `libbrotlidec` |
| `libbz2-1.dll` | Dekompresor bzip2 | Zależność `libfreetype` |
| `libssp-0.dll` | GCC Stack Smashing Protector | Zależność runtime MinGW GCC |
| `libstdc++-6.dll` | Biblioteka standardowa C++ | Zależność C++ dla bibliotek dynamicznych |
| `libgcc_s_seh-1.dll` | Obsługa wyjątków GCC SEH | Zależność runtime MinGW GCC |
| `libwinpthread-1.dll` | Implementacja wątków POSIX dla Windows | Zależność runtime MinGW |

> **Uwaga dot. R7**: Wszystkie biblioteki klienta (`bzip2`, `lz4`, `readline`, `liblua`, `libjansson`, `mbedtls`, `whereami`, `tinycbor`, `reveng`) są **w 100% zlinkowane statycznie** wewnątrz pliku `proxmark3.exe`. Powyższe biblioteki DLL reprezentują wyłącznie zależności dynamicznych wyjątków (`libgd` i `python312`).

---

## 4. Weryfikacja wymagań (EARS)

| ID | Wymaganie | Stan | Dowód weryfikacji |
|---|---|---|---|
| **R1** | System wyprodukuje poprawny plik PE32+ dla targetu x86_64 bez użycia Windows/ProxSpace. | **Zrealizowane** | `file client/proxmark3.exe` → `PE32+ executable for MS Windows 5.02 (console), x86-64, 20 sections`. |
| **R2** | Wywołania `pkg-config` są ściśle izolowane do sysrootu MinGW i nie linkują obiektów Linuksa. | **Zrealizowane** | `PKG_CONFIG_LIBDIR=/usr/x86_64-w64-mingw32/lib/pkgconfig PKG_CONFIG_PATH=`. W logach kompilacji brak flag `-I/usr/include` czy `-L/usr/lib`. |
| **R3** | `proxmark3.exe` uruchamia się pod Wine z flagą `--help` i kończy kodem 0 bez błędów DLL. | **Zrealizowane** | `wine client/proxmark3.exe --help` oraz `wine client/proxmark3.exe -v` działają poprawnie, kod wyjścia 0. |
| **R4** | Wsparcie dla `libgd` (PNG, JPEG, FreeType) jest włączone w binarce. | **Zrealizowane** | Pakiety AUR skompilowane z flagami formatów, `HAVE_GD` aktywne, `libgd.dll` poprawnie załadowane. |
| **R5** | Wsparcie dla Readline, vendored Lua, vendored Jansson i Python-embed jest włączone. | **Zrealizowane** | Symbole obecne w binarce, skrypty Lua/Python obsługiwane, wygenerowany `python3-embed.pc`. |
| **R6** | CI GitHub Actions automatycznie buduje i weryfikuje binarkę pod kątem poprawności PE32+ i DLL. | **Zrealizowane** | Workflow `.github/workflows/mingw-cross.yml` zintegrowany z testami `file`, `objdump`, `wine` i uploadem artefaktu. |
| **R7** | Runtime MinGW jest zlinkowany statycznie, zapobiegając niekontrolowanemu wyciekowi DLL. | **Zrealizowane** | `objdump -p client/proxmark3.exe` potwierdza brak bezpośrednich powiązań z `libstdc++-6.dll` czy `libgcc_s`. |

---

## 5. Matryca zadań inżynieryjnych (T1 – T12)

- [x] **T1 (Toolchain & Build Flags)**: Instalacja `mingw-w64-gcc`, konfiguracja sysrootu `/usr/x86_64-w64-mingw32/`, implementacja bloku `CROSS_MINGW=1` w `Makefile.defs` z izolacją `PKG_CONFIG_LIBDIR`.
- [x] **T2 (bzip2 target mingw)**: Przygotowanie pakietu AUR `mingw-w64-bzip2` z łatą `_architectures="x86_64-w64-mingw32"`.
- [x] **T3 (lz4 target mingw)**: Przygotowanie pakietu AUR `mingw-w64-lz4`.
- [x] **T4 (readline target mingw)**: Przygotowanie pakietu AUR `mingw-w64-readline` wraz z `mingw-w64-termcap`.
- [x] **T5 (vendored Lua)**: Weryfikacja i dostosowanie `client/deps/liblua` pod kompilator `x86_64-w64-mingw32-gcc`.
- [x] **T6 (vendored Jansson)**: Weryfikacja i kompilacja `client/deps/jansson` pod MinGW.
- [x] **T7 (Python 3.12 Embed)**: Instalacja AUR `mingw-w64-python312-bin`, ręczne wygenerowanie pliku `/usr/x86_64-w64-mingw32/lib/pkgconfig/python3-embed.pc`, zabezpieczenie linkowania dynamicznego w `client/Makefile`.
- [x] **T8 (Łańcuch GD)**: Sekwencyjna budowa w sysroocie: `zlib` → `brotli` → `libpng` / `freetype2-bootstrap` / `libjpeg-turbo` → `gd` z flagami `-DENABLE_GD_FORMATS=1 -DENABLE_PNG=1 -DENABLE_JPEG=1 -DENABLE_FREETYPE=1`.
- [x] **T9 (Integracja linkera)**: Dodanie flag `-static -static-libgcc -static-libstdc++ -Wl,-Bstatic` oraz `-Wl,--allow-multiple-definition`. Ukończenie budowy `client/proxmark3.exe`.
- [x] **T10 (Wine smoke test & VC++ Redist Fix)**: Pomyślny test dymny pod Wine. Zidentyfikowanie braku `VCRUNTIME140.dll` na realnym Windowsie i dodanie ekstrakcji z instalatora Microsoft VC Redistributable.
- [x] **T11 (Infrastruktura CI/CD)**: Wdrożenie workflow `.github/workflows/mingw-cross.yml` opartego na dedykowanym runnerze hosta Arch Linux (`bh-local`), eliminującego potrzebę budowania kontenera w chmurze i skracającego czas CI do kilkunastu sekund. Pakowanie do archiwum `proxmark3-windows-x64.tar.gz`.
- [x] **T12 (Dokumentacja i higiena forka)**: Uporządkowanie specyfikacji technicznej w `docs/specs/mingw-cross-build.md`, aktualizacja `.agents/PROJECT-CONTEXT.md`, wyłączenie zbędnych platformowych buildów upstreamu i aktywacja ochrony leak-guard.

---

## 6. Procedura lokalnego uruchomienia

Do zbudowania klienta Windowsowego z poziomu stacji roboczej Linux (Arch Linux) wystarczy wywołać:

```bash
# Jednorazowa kompilacja klienta Proxmark3 pod Windows x86_64:
make CROSS_MINGW=1 SKIPBT=1 SKIPQT=1 SKIPREVENGTEST=1 \
     CC='ccache x86_64-w64-mingw32-gcc' CXX='ccache x86_64-w64-mingw32-g++' \
     client

# Skopiowanie niezbędnych bibliotek DLL do katalogu client/:
cd client
for f in libgd libssp-0 libstdc++-6 libfreetype-6 libjpeg-8 libpng16-16 zlib1 python312 \
         libgcc_s_seh-1 libwinpthread-1 libbrotlidec libbrotlicommon libbz2-1 vcruntime140; do
  cp "/usr/x86_64-w64-mingw32/bin/${f}.dll" .
done

# Weryfikacja działania pod Wine:
wine proxmark3.exe -v
```

Alternatywnie cały proces jest zautomatyzowany w skrypcie:
```bash
bash .github/scripts/mingw-cross-build.sh
```

---

## 7. Zweryfikowany stan (verified:)

```
verified: 2026-09-21
verified_by:
  1. Kompilacja i staging:
     bash .github/scripts/mingw-cross-build.sh (exit code: 0)
  2. Weryfikacja formatu pliku wykonywalnego:
     file client/proxmark3.exe -> "PE32+ executable for MS Windows 5.02 (console), x86-64, 20 sections"
  3. Inspekcja importów PE (brak wycieków linuksowych bibliotek):
     objdump -p client/proxmark3.exe | grep "DLL Name"
     Wynik: ADVAPI32.dll, libgd.dll, KERNEL32.dll, api-ms-win-crt-*, python312.dll, USER32.dll, WS2_32.dll
  4. Test uruchomieniowy pod Wine:
     wine client/proxmark3.exe -v
     Wynik:
     Client: Iceman/master/v4.21611-1274-g61aa32491-suspect
     compiler: MinGW-w64 16.2.0 OS:Windows (64b) ARCH:x86_64
     Exit code: 0
  5. Test pomocy:
     wine client/proxmark3.exe --help (exit code: 0)
  6. Pipeline CI/CD:
     GitHub Actions Workflow: .github/workflows/mingw-cross.yml (Pass)
     Workflow leak-guard: .github/workflows/public-fork-leak-guard.yml (Pass)
```
