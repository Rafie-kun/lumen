#!/usr/bin/env bash
# Portable build: compile bin/lumen inside Ubuntu 22.04 (glibc 2.35) with the
# ABI gated to glibc 2.34 by scripts/check-abi.sh, so it runs on any x86_64
# distro with glibc >= 2.34. Mirrors SLSsteam-fork/scripts/.
# Falls back to a host build when no container runtime is available (CI).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

runtime=""
for c in podman docker; do
  if command -v "$c" >/dev/null 2>&1; then runtime="$c"; break; fi
done

if [ -n "$runtime" ]; then
  echo "==> portable build (using $runtime, image lumen-builder)"
  "$runtime" build -f Dockerfile -t lumen-builder . >&2
  "$runtime" run --rm -v "$PWD:/build:Z" -w /build lumen-builder \
    bash -c 'make clean && make'
else
  echo "==> no container runtime found; falling back to host build"
  make clean
  make
fi
scripts/check-abi.sh bin/lumen
echo "==> built: bin/lumen"
