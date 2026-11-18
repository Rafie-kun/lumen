#!/usr/bin/env bash
# Gate the shipped lumen binary to the project's glibc 2.34 floor.
#
# scripts/_build-portable.sh compiles inside Ubuntu 22.04, which is glibc 2.35
# rather than 2.34. Building there does not by itself guarantee the "glibc >=
# 2.34" promise in README.md: a call into a 2.35-only symbol would silently
# raise the minimum. This check reads the produced binary's symbol versions and
# refuses anything newer than GLIBC_2.34, the same way
# slsteam-moon/scripts/check-sls-abi.sh does for the hook library.

set -euo pipefail

BINARY="${1:-bin/lumen}"
READELF_BIN="${READELF:-readelf}"

if [ ! -s "$BINARY" ]; then
	echo "lumen binary is missing or empty: $BINARY" >&2
	exit 1
fi
if [ ! -x "$READELF_BIN" ] && ! command -v "$READELF_BIN" >/dev/null 2>&1; then
	echo "readelf is required to verify the lumen ABI" >&2
	exit 1
fi

HEADER_OUTPUT="$(mktemp)"
VERSION_OUTPUT="$(mktemp)"
cleanup() {
	rm -f "$HEADER_OUTPUT" "$VERSION_OUTPUT"
}
trap cleanup EXIT

if ! "$READELF_BIN" --file-header "$BINARY" >"$HEADER_OUTPUT" 2>&1; then
	echo "could not inspect lumen ELF header: $BINARY" >&2
	exit 1
fi
if ! grep -Eq 'Class:[[:space:]]+ELF64' "$HEADER_OUTPUT" \
   || ! grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' "$HEADER_OUTPUT"; then
	echo "$BINARY is not an ELF64 X86-64 binary" >&2
	exit 1
fi

if ! "$READELF_BIN" --version-info "$BINARY" >"$VERSION_OUTPUT" 2>&1; then
	echo "could not inspect lumen GLIBC requirements: $BINARY" >&2
	exit 1
fi

VERSIONS="$(sed -n \
	's/.*Name: GLIBC_\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p' \
	"$VERSION_OUTPUT")"
if [ -z "$VERSIONS" ]; then
	# A fully static build has no dynamic version requirements to enforce.
	echo "lumen has no dynamic GLIBC requirements; glibc floor is not applicable"
	exit 0
fi

while read -r major minor; do
	case "$major:$minor" in
		*[!0-9:]*|:*)
			echo "invalid GLIBC requirement in $BINARY" >&2
			exit 1
			;;
	esac
	if [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -gt 34 ]; }; then
		echo "$BINARY requires GLIBC_${major}.${minor}; maximum allowed is GLIBC_2.34" >&2
		exit 1
	fi
done <<< "$VERSIONS"

echo "lumen ABI is compatible with ELF64 X86-64 and GLIBC_2.34"
