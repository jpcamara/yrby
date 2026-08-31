# Multi-stage build for the yrby site.
#
#   docker build -t yrby-site .
#   docker run -p 3000:3000 -e SECRET_KEY_BASE=$(openssl rand -hex 64) yrby-site
#
# Three stages: gems, then the bun bundle, then a runtime image that carries
# neither toolchain. The final image is Ruby slim plus the gems and the built
# assets — no Rust (yrby ships precompiled platform gems), no Node, no bun.
ARG RUBY_VERSION=3.4.5

# --- gems ---------------------------------------------------------------------
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS gems
WORKDIR /rails

# build-essential is here for any gem that still needs a C toolchain. yrby and
# commonmarker both resolve to precompiled platform gems, so nothing Rust is
# compiled during this build.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test"

COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

# --- demo bundles -------------------------------------------------------------
FROM docker.io/oven/bun:1 AS assets
WORKDIR /build
COPY frontend/package.json frontend/bun.lock frontend/bunfig.toml ./frontend/
RUN cd frontend && bun install --frozen-lockfile
COPY frontend ./frontend
RUN cd frontend && bun build.mjs

# --- runtime ------------------------------------------------------------------
FROM docker.io/library/ruby:$RUBY_VERSION-slim
WORKDIR /rails

# curl is the health check; the rest of the toolchain does not ship.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test"

# thrust listens on HTTP_PORT and proxies to Falcon on TARGET_PORT (thrust sets
# PORT to this value for its upstream, and bin/serve turns that into Falcon's
# --bind). The anycable-go embedded in thrust answers /cable itself and never
# proxies it.
ENV HTTP_PORT="3000" TARGET_PORT="3001"

# The embedded Go server calls Rails at the mounted RPC path over localhost.
ENV ANYCABLE_RPC_HOST="http://localhost:3001/_anycable"

# No Redis: one node, so Rails posts broadcasts straight back to the Go server.
# The broadcast endpoint gets its own port on purpose — with a secret
# configured, anycable-go otherwise mounts /_broadcast on the main port, and
# mounting it there displaces thrust's proxy routing.
ENV ANYCABLE_BROADCAST_ADAPTER="http" ANYCABLE_HTTP_BROADCAST_PORT="8090"

# Layer 0 of the throttle stack: an over-size frame is refused at the socket and
# never becomes an RPC call. Same number as Limits::MAX_FRAME_BYTES.
ENV ANYCABLE_MAX_MESSAGE_SIZE="131072"

# Forward the client address so the per-IP connection cap sees the visitor
# rather than whatever proxy sits in front.
ENV ANYCABLE_HEADERS="cookie,x-forwarded-for"

# ANYCABLE_SECRET and SECRET_KEY_BASE are supplied at runtime. The first
# configures both halves of AnyCable: the HTTP RPC key and the broadcast key are
# derived from it on the Ruby side and the Go side alike.

COPY --from=gems /usr/local/bundle /usr/local/bundle
COPY . .
COPY --from=assets /build/public /rails/public

# Digest the stylesheet at build time so a request never pays for it. No
# database and no secrets are needed for this; the dummy key is discarded.
RUN SECRET_KEY_BASE=dummy bundle exec rails assets:precompile

RUN useradd rails --create-home --shell /bin/bash && \
    chown -R rails:rails log tmp public
USER rails:rails

EXPOSE 3000

# One command runs the proxy, the embedded AnyCable server, and Falcon.
# bin/serve pins Falcon to ONE worker and refuses to boot otherwise — the
# document store is a Hash in that process's memory.
CMD ["bundle", "exec", "thrust", "./bin/serve"]
