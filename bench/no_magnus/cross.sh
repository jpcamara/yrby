#!/bin/sh
# Cross-build the spike's C build for one platform in rake-compiler-dock's
# image (which has arm64 variants, so it runs natively on an Apple Silicon
# Docker host). Installs a minimal Rust toolchain in the container.
# Usage: bench/no_magnus/cross.sh RCD_PLATFORM RUST_TARGET [LINKER_ENV]
set -e
platform=$1 target=$2 linker=$3
image=ghcr.io/rake-compiler/rake-compiler-dock-image:1.10.0-mri-$platform
docker run --rm -v "$(pwd)":/work -w /work \
  -e RCD_PLATFORM="$platform" -e CARGO_BUILD_TARGET="$target" \
  -e CARGO_TARGET_DIR=/tmp/cargo-target $linker \
  "$image" bash -lc '
    set -e
    curl -sSf https://sh.rustup.rs | sh -s -- -y -q --profile minimal --target "$CARGO_BUILD_TARGET" >/dev/null
    . "$HOME/.cargo/env"
    gem install rake-compiler --no-document -q >/dev/null 2>&1 || true
    v=$(echo "$RUBY_CC_VERSION" | tr ":" "\n" | grep "^3\.4" | head -1)
    echo "ruby $v, target $CARGO_BUILD_TARGET"
    rake -f bench/no_magnus/cross.rake cross compile RUBY_CC_VERSION="$v"
    find tmp/$RCD_PLATFORM -name "yrby_c.so" -exec ls -l {} \; -exec file {} \;
  '
