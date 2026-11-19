# Lumen

A lightweight, millennium-less bridge for slsteam-moon: a single static Lua
binary that injects the LuaTools frontend through Steam's CEF remote-debugging
endpoint (CDP) and hosts the Lua backend over a loopback RPC.

## Build (portable, any x86_64 distro, glibc >= 2.34)
    scripts/_build-portable.sh    # outputs bin/lumen
    scripts/check-abi.sh          # enforces ELF64 x86-64 and the glibc 2.34 floor

The build image is Ubuntu 22.04, whose glibc is 2.35, so `check-abi.sh` is what
makes the 2.34 claim true. It runs from `_build-portable.sh` and `package.sh`;
a host build on a newer distro will fail it.

## Host unit tests
    tools/run_all_tests.sh        # needs bin/lumen plus lua5.4 and node

## Docs

- [Added games: Workshop, ownership tickets, update loops](docs/added-games-troubleshooting.md)
- [ARM (aarch64) feasibility](docs/arm-feasibility.md)
