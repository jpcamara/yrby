# The Rails side of the Rails <-> Loco interop test: Ruby, plus Rust to build
# yrby's native extension, plus libclang for rb-sys' bindgen. The repo is
# mounted read-only and copied in, so the build never writes to the checkout.
FROM ruby:3.4-bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends clang libclang-dev sqlite3 rsync \
 && rm -rf /var/lib/apt/lists/*
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
ENV PATH=/root/.cargo/bin:$PATH \
    BUNDLE_PATH=/bundle \
    CARGO_TARGET_DIR=/cargo-target
WORKDIR /work
