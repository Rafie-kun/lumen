# ARM (aarch64) feasibility for the SLSsteam / LuaTools / Lumen stack

Scope: running added games with achievements, Workshop and the Lumen menu on
Linux/ARM64. No specific device is assumed. This report is based on the code in
this workspace (`ace-sls`, `slsteam-moon`, `luatools-moon`, `lumen`) and on
public information about Valve's ARM64 client.

## Short answer

Feasible in two different ways, with very different costs:

| Route | Verdict | What it needs |
| --- | --- | --- |
| Native ARM64 client + native stack | Possible for SLSsteam/Lumen, not for the Careca pack | aarch64 build of SLSsteam, aarch64 ports of the pattern catalogues and the achievements plugin, an ARM64 LuaTools fork |
| x86-64 Steam client under FEX/box64 | Works today, with the same limits as x86 | nothing arch-specific, but translation overhead and per-game compatibility |

For most users the second route is the practical one; the first is a real port,
not a recompile.

## Component by component

### SLSsteam (`ace-sls`) — buildable for ARM64, needs testing

Upstream already has an ARM64 target:

- `Makefile`: `CROSS_HOST=AArch64` selects `aarch64-linux-gnu-g++` and adds
  `-DAARCH64`.
- `make-releases.sh`: sets `CROSS_HOST=AArch64` and an aarch64 pkg-config path,
  so releases are built by cross-compiling.
- `src/patterns.cpp`: 17 `#ifdef AARCH64` signature/prologue pairs next to the
  x86_64 ones.
- `src/decompiler.cpp`: ARM decoder (`CARMEmu`) used when `AARCH64` is defined;
  the x86 decompiler path is skipped.
- `lib/aarch64/`: prebuilt `liblibmem.a`, `libluajit.a`, `libprotobuf.a`,
  `libyaml-cpp.a`.
- `src/main.cpp`: release type reports `AArch64`.

Gaps: `pkg/*/PKGBUILD` are `arch=("x86_64")` only, so no ARM package exists, and
the aarch64 signatures cover the patterns that were ported — each Steam client
update moves them, and a port has to keep up on both architectures. There is no
aarch64 cross toolchain (or dbus/curl aarch64 dev files) on this machine, so a
build could not be attempted here.

### `slsteam-moon` — x86-64 only today

- 79 byte-pattern signatures in `src/patterns.cpp`, no `#ifdef` architecture
  branches (unlike `ace-sls`).
- `lib/` holds a single-architecture `liblibmem.a`, no `lib/aarch64`.
- Hooks are located by those patterns and by x86 symbol/prologue conventions.

Porting it means writing 79 ARM64 signature variants plus an ARM64 prologue
matcher, and keeping both catalogues current through client updates. It is the
largest single piece of work in the native route.

### LuaTools (`luatools-moon`) — architecture-neutral, except what it ships

The plugin backend is Lua and the frontend is JS (`plugin/backend/*.lua`,
`plugin/public`), so it runs unchanged on ARM64; its work (licences, depot keys,
stplug-in files, downloader manifests) is file-based. What is *not* neutral is
the slsteam-moon/Careca library it launches Steam with — that is the native part
above. `dist/` here is a plugin bundle, not a native binary.

### Careca x64 pack — closed, x86-64 only

`~/.local/share/SLSsteam-careca-x64/SLSsteam.so` is a prebuilt, closed x86-64
library with the careca UI. There is no source to rebuild and no ARM64 artifact.
On an ARM64 host it cannot be loaded natively at all, so the Careca route on ARM
means running the x86 client under emulation.

### Achievements plugin — needs a real port

`lumen/lua/slsachievements.lua` embeds a LuaJIT plugin that:

- finds three achievement-guard call sites by scanning for `0xE8` (x86 `call
  rel32`) instructions and pairing them with `FF 25` (x86 GOT-indirect `jmp`)
  stubs,
- resolves `_ZN5CUser12isSubscribedEj` (the `CUser::isSubscribed(unsigned int)`
  symbol) and rewrites the calls to skip the ownership check.

On ARM64 the call encoding is `BL` (imm26), the indirect jump is a different
sequence (`ADRP`/`LDR`/`BR`), and the call sites must be found from ARM
prologues. The symbol name itself is ABI-mangled and would resolve, but the
patching logic is entirely x86-specific. This is a contained port (one file, a
handful of sites) but it cannot be reused as is.

### Lumen — recompile only

- `src/` is C (`main.c`, `cdp`, `http_binding`, `private_fs`, `cainfo`) and the
  rest is Lua; nothing is x86-specific.
- `Makefile` uses the host compiler (`CC ?= cc`), statically links `liblua5.4.a`
  and (in the portable build) static curl/OpenSSL from the build container.
- It talks to Steam over CDP, not by patching memory, so the architecture of the
  client does not matter.

An ARM64 build needs an aarch64 `liblua5.4.a` and the static curl/OpenSSL set,
or a container-based build for that architecture. The menu, the Workshop status
row and the Steam-update guard work the same way.

## Native ARM64 route: the client itself

Valve ships an ARM64 Linux client on the public beta channel
(`steam_client_publicbeta_linuxarm64`), not as a stable default. Known limits:

- The binaries are linked with 4K segment alignment, so they fail to load on
  16K-page kernels (Asahi Linux, some ARM servers) with
  `ELF load command address/offset not page-aligned`; those systems have to run
  the client inside a 4K-page VM (`muvm`), which also forces every game into it.
  See ValveSoftware/steam-for-linux#13745.
- ARM64 Steam is young: the Steam runtime, the pressure-vessel container and
  Proton for ARM are still moving targets.
- There is no ARM64 build of the x86-only Windows game binaries; games run
  through Proton x86-on-ARM translation (FEX) where it is available.

Consequence: even with a native SLSsteam + Lumen, the games themselves usually
still need translation, so "native" only removes translation for Steam and the
injected libraries.

## x86-64 client under FEX/box64: the practical route

Running the ordinary x86-64 Steam client through FEX-Emu or box64 keeps every
component in this stack unchanged: SLSsteam x86-64, the Careca pack, the
achievements plugin, LuaTools and Lumen all work exactly as documented here.
Costs are the translation overhead for Steam itself and the usual per-game
compatibility of x86 games on ARM (Proton + FEX, box64, or native ARM ports).

This is also the only route that keeps the closed Careca pack usable.

## Effort estimate for the native route

1. aarch64 build environment for `ace-sls` (cross toolchain, dbus/curl/protobuf
   aarch64 dev files, `CROSS_HOST=AArch64`) and an ARM64 package — days,
   mostly packaging and validating against a live ARM64 client.
2. `slsteam-moon`: 79 ARM64 patterns + prologue matcher + aarch64 libmem —
   the dominant cost, weeks, and permanent double maintenance.
3. Achievements plugin: ARM64 site discovery + `BL` rewriting — contained.
4. Lumen: rebuild against aarch64 static deps — small.
5. LuaTools: no port needed.
6. Careca: not portable (closed binary); its features would have to be
   reimplemented in open code (which is largely what `slsteam-moon` already is).

## Recommendation

- Today: x86-64 client under FEX/box64. Everything in this stack, including the
  Workshop workaround and the achievements toggle, behaves as on x86-64.
- Native: start with `ace-sls` aarch64 packaging and the Lumen rebuild (both
  cheap), and treat `slsteam-moon`'s pattern catalogue as the gating item. Do
  not plan on the Careca pack on ARM.

## Sources

- `ace-sls`: `Makefile`, `make-releases.sh`, `src/patterns.cpp`,
  `src/decompiler.cpp`, `lib/aarch64/`, `pkg/*/PKGBUILD`
- `slsteam-moon`: `src/patterns.cpp`, `lib/`
- `luatools-moon`: `plugin/backend/`, `dist/plugin.json`
- `lumen`: `src/`, `Makefile`, `lua/slsachievements.lua`
- ValveSoftware/steam-for-linux#13745 (ARM64 client, 4K page alignment)
- Valve's ARM64 Linux client beta channel (`steam_client_publicbeta_linuxarm64`)
