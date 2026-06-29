# Containerized yrby actioncable demo.
#
# Build context is the yrby repo ROOT (see docker-compose.yml), because the
# demo depends on the gem via `path: "../.."` and on yrby-client via
# `file:../../../packages/client`. The Lexxy editor page additionally
# depends on lexxy-realtime, a SIBLING repo (`file:../../../../lexxy-realtime`),
# which we clone so the relative path resolves. We mirror the host layout exactly
# under /src so every existing relative path Just Works:
#
#   /src/yrby          <- this repo (gem source + demo)
#   /src/lexxy-realtime    <- cloned sibling (the Lexxy front end)
#
# The image carries Rust (to compile the native extension) and bun (to build the
# front-end bundles), then boots Puma. Postgres + Redis are separate services.
FROM ruby:3.4-bookworm

# System deps: build toolchain + libpq (pg gem), postgres client (db checks),
# git/curl/unzip for fetching Rust, bun, and the sibling repo.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential clang libpq-dev postgresql-client git curl ca-certificates unzip \
 && rm -rf /var/lib/apt/lists/*

# Rust toolchain for the yrby native extension (rb_sys/magnus).
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"

# bun for the front-end build.
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

# The Lexxy front-end page consumes lexxy-realtime from the sibling location the
# demo's package.json points at (../../../../lexxy-realtime => /src/lexxy-realtime).
ARG LEXXY_REALTIME_REF=main
RUN git clone --depth 1 --branch "${LEXXY_REALTIME_REF}" \
      https://github.com/jpcamara/lexxy-realtime.git /src/lexxy-realtime

# The repo (build context root) lands at /src/yrby so `path: "../.."` resolves.
WORKDIR /src/yrby
COPY . /src/yrby

# Compile the native extension for the image's platform. A `path:` gem is NOT
# auto-compiled by the consumer's `bundle install` (only published gems are), so
# build it explicitly into lib/y/y_ruby.so -- otherwise the loader's
# require fails at runtime. (The Linux platforms are added because the committed
# lockfiles were resolved on macOS.)
RUN cd /src/yrby \
 && bundle lock --add-platform x86_64-linux aarch64-linux \
 && bundle install \
 && bundle exec rake compile

# yrby-client (a file: dep of the front end) ships from a `dist/` that is NOT
# committed and has no install-time build hook, so build it explicitly first --
# the demo's `bun install` then copies the fresh dist.
RUN cd /src/yrby/packages/client && bun install && bun run build

WORKDIR /src/yrby/examples/actioncable-demo

# Install the demo's gems (the native ext is already compiled above), then build
# the front-end bundles.
RUN bundle lock --add-platform x86_64-linux aarch64-linux
RUN bundle install
RUN cd frontend && bun install && bun run build

EXPOSE 3000

# db:prepare creates/migrates the durable-store schema on first boot; entrypoint
# waits for Postgres (compose marks it healthy, but belt-and-suspenders).
CMD ["bash", "-lc", "bin/rails db:prepare && bin/rails server -b 0.0.0.0 -p 3000"]
