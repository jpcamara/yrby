#!/bin/bash
# Compiles src/pixel_studio.rb into a WebAssembly reactor module with Spinel.
#
# Needs a Spinel checkout built with `make && make wasm-rt` (SPINEL_HOME) and
# wasi-sdk 34 or later (WASI_SDK). The build flags come from
# `spinel --print-build`, so they follow the Spinel version in use.
#
#   SPINEL_HOME=~/src/spinel WASI_SDK=/opt/wasi-sdk ./build-wasm.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
: "${SPINEL_HOME:?point SPINEL_HOME at a Spinel checkout}"
WASI_SDK=${WASI_SDK:-/opt/wasi-sdk}
spinel=$SPINEL_HOME/spinel
out=${1:-$here/build}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

cp "$here/src/pixel_studio.rb" "$here/src/exports.c" "$work/"
cd "$work"
"$spinel" pixel_studio.rb -c --force --target=wasm32-wasi \
  --ext-init pixel_studio_init --ext-entry Pixel.start,Pixel.dispatch -o pixel_studio.c >/dev/null

flags=() links=() libs=() runtime=""
while read -r kind value; do
  case $kind in
    include) flags+=("-I$value") ;;
    define|cflag) flags+=("$value") ;;
    link) links+=("$value") ;;
    runtime) runtime=$value ;;
    lib) libs+=("$value") ;;
  esac
done < <("$spinel" pixel_studio.rb --target=wasm32-wasi --print-build)

# Every Host function, and host_error from exports.c, is a JavaScript import.
{ grep -o 'ffi_func :host_[a-z_]*' pixel_studio.rb | sed 's/ffi_func ://'; echo host_error; } > imports.txt

"$WASI_SDK/bin/clang" --target=wasm32-wasip1 -O2 -mexec-model=reactor -I. "${flags[@]}" \
  -Wno-everything -Wl,--allow-undefined-file=imports.txt \
  -Wl,--export=malloc -Wl,--export=free \
  pixel_studio.c exports.c "${links[@]}" "$runtime" "${libs[@]}" -o "$out/pixel_studio.wasm"

"$spinel" --version > "$out/SPINEL-VERSION"
ls -l "$out/pixel_studio.wasm"
