#!/bin/bash
# Compiles src/pixel_studio.rb into a WebAssembly reactor module with Spinel,
# with yrs (y-crdt's yffi C API) linked into the same module.
#
# Needs a Spinel checkout built with `make && make wasm-rt` (SPINEL_HOME),
# wasi-sdk 34 or later (WASI_SDK), and a y-crdt checkout at v0.28.0 (YCRDT)
# with rustup's wasm32-wasip1 target. The build flags come from
# `spinel --print-build`, so they follow the Spinel version in use.
#
#   git clone --branch v0.28.0 https://github.com/y-crdt/y-crdt.git ~/src/y-crdt
#   rustup target add wasm32-wasip1
#   SPINEL_HOME=~/src/spinel WASI_SDK=/opt/wasi-sdk YCRDT=~/src/y-crdt ./build-wasm.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
: "${SPINEL_HOME:?point SPINEL_HOME at a Spinel checkout}"
: "${YCRDT:?point YCRDT at a y-crdt checkout}"
WASI_SDK=${WASI_SDK:-/opt/wasi-sdk}
spinel=$SPINEL_HOME/spinel
out=${1:-$here/build}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

# yrs leaves out its default undo options on WebAssembly, which yffi's
# yundo_manager uses. The patch spells them out with the WASI clock.
if git -C "$YCRDT" apply --check "$here/yffi-wasi.patch" 2>/dev/null; then
  git -C "$YCRDT" apply "$here/yffi-wasi.patch"
fi
# Size-tuned with link-time optimization: about 0.3 MB smaller than the default.
(cd "$YCRDT" && RUSTFLAGS=-Awarnings CARGO_PROFILE_RELEASE_OPT_LEVEL=s \
  CARGO_PROFILE_RELEASE_LTO=true CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
  cargo build --quiet -p yffi --release --target wasm32-wasip1 --target-dir target/spinel-wasm)
yrs=$YCRDT/target/spinel-wasm/wasm32-wasip1/release/libyrs.a

# Integer is 32 bits on wasm32. Client IDs reach 53 bits, so overflow
# promotes to a bignum rather than raising.
target=(--target=wasm32-wasi --int-overflow=promote)

cp "$here"/src/*.rb "$here"/src/*.c "$work/"
cd "$work"
"$spinel" pixel_studio.rb -c --force "${target[@]}" \
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
done < <("$spinel" pixel_studio.rb "${target[@]}" --print-build)

# Every Host function, and host_error from exports.c, is a JavaScript import.
{ grep -o 'ffi_func :host_[a-z_]*' pixel_studio.rb | sed 's/ffi_func ://'; echo host_error; } > imports.txt

"$WASI_SDK/bin/clang" --target=wasm32-wasip1 -O2 -mexec-model=reactor -I. -I"$YCRDT/tests-ffi/include" \
  "${flags[@]}" -Wno-everything -Wl,--allow-undefined-file=imports.txt \
  -Wl,--export=malloc -Wl,--export=free -Wl,--strip-debug \
  pixel_studio.c exports.c yrs_glue.c "${links[@]}" "$runtime" "${libs[@]}" "$yrs" -o "$out/pixel_studio.wasm"

"$spinel" --version > "$out/SPINEL-VERSION"
cp "$YCRDT/LICENSE" "$out/YRS-LICENSE"
ls -l "$out/pixel_studio.wasm"
